// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IHookReceiver} from "silo-core/contracts/interfaces/IHookReceiver.sol";
import {ISiloConfig} from "silo-core/contracts/interfaces/ISiloConfig.sol";
import {ISilo} from "silo-core/contracts/interfaces/ISilo.sol";
import {IERC20} from "openzeppelin5/token/ERC20/IERC20.sol";
import {IShareToken} from "silo-core/contracts/interfaces/IShareToken.sol";

import {Hook} from "silo-core/contracts/lib/Hook.sol";
import {BaseHookReceiver} from "silo-core/contracts/utils/hook-receivers/_common/BaseHookReceiver.sol";
import {GaugeHookReceiver} from "silo-core/contracts/utils/hook-receivers/gauge/GaugeHookReceiver.sol";

/**
 * @title ResponderSiloHook
 * @notice Hook for responder silos that manages direct deposits and borrowing operations.
 * Coordinates with the controller silo to handle liquidity needs.
 */
contract ResponderSiloHook is GaugeHookReceiver {
    address public responderSilo;
    address public controllerSilo;
    address public controllerHook;

    // Track real and virtual assets
    uint256 public realAssets;
    uint256 public virtualAssets;

    // Safety mechanisms
    bool public emergencyPause;
    uint256 public minLiquidityBuffer = 5; // 5% buffer

    event DirectDepositReceived(
        address indexed user,
        uint256 assets,
        uint256 shares
    );
    event ControllerDepositReceived(uint256 assets, uint256 shares);
    event WithdrawalProcessed(
        address indexed user,
        uint256 assets,
        uint256 shares
    );
    event BorrowProcessed(address indexed borrower, uint256 assets);
    event PositionPulledFromController(uint256 assets, uint256 shares);
    event EmergencyPauseSet(bool paused);
    event MinLiquidityBufferSet(uint256 buffer);
    event ControllerHookSet(address hook);

    error ResponderHook_Paused();
    error ResponderHook_InsufficientLiquidity();
    error ResponderHook_ZeroAddress();
    error ResponderHook_InvalidController();

    /**
     * @dev Initializer for the responder hook
     * @param _siloConfig The SiloConfig for the marketplace
     * @param _data Initialization data (owner, asset, controller)
     */
    function initialize(
        ISiloConfig _siloConfig,
        bytes calldata _data
    ) external override initializer {
        (address owner, address asset, address controller) = abi.decode(
            _data,
            (address, address, address)
        );

        if (controller == address(0)) {
            revert ResponderHook_ZeroAddress();
        }

        controllerSilo = controller;

        // Initialize base hook receiver and gauge hook receiver
        BaseHookReceiver.__BaseHookReceiver_init(_siloConfig);
        GaugeHookReceiver.__GaugeHookReceiver_init(owner);

        // Identify which silo in the config is using our asset
        (address silo0, address silo1) = _siloConfig.getSilos();
        if (ISilo(silo0).asset() == asset) {
            responderSilo = silo0;
        } else if (ISilo(silo1).asset() == asset) {
            responderSilo = silo1;
        } else {
            revert("Invalid asset for silo");
        }

        // Verify controller has the same asset
        require(
            ISilo(controllerSilo).asset() == asset,
            "Controller asset mismatch"
        );

        // Configure hooks
        (uint256 hooksBefore, uint256 hooksAfter) = _hookReceiverConfig(
            responderSilo
        );

        // Add deposit, withdraw, borrow and liquidation hooks
        hooksAfter = Hook.addAction(
            hooksAfter,
            Hook.DEPOSIT | Hook.COLLATERAL_TOKEN
        );

        hooksBefore = Hook.addAction(
            hooksBefore,
            Hook.WITHDRAW | Hook.COLLATERAL_TOKEN
        );
        hooksBefore = Hook.addAction(hooksBefore, Hook.BORROW);
        hooksBefore = Hook.addAction(hooksBefore, Hook.LIQUIDATION);

        _setHookConfig(responderSilo, hooksBefore, hooksAfter);
    }

    // Admin functions

    /**
     * @notice Set emergency pause
     * @param _paused Whether to pause operations
     */
    function setEmergencyPause(bool _paused) external onlyOwner {
        emergencyPause = _paused;
        emit EmergencyPauseSet(_paused);
    }

    /**
     * @notice Set minimum liquidity buffer (in percentage)
     * @param _buffer New buffer percentage (0-100)
     */
    function setMinLiquidityBuffer(uint256 _buffer) external onlyOwner {
        require(_buffer <= 100, "Buffer must be <= 100");
        minLiquidityBuffer = _buffer;
        emit MinLiquidityBufferSet(_buffer);
    }

    /**
     * @notice Set the controller hook address
     * @param _controllerHook The controller hook address
     */
    function setControllerHook(address _controllerHook) external onlyOwner {
        if (_controllerHook == address(0)) {
            revert ResponderHook_ZeroAddress();
        }
        controllerHook = _controllerHook;
        emit ControllerHookSet(_controllerHook);
    }

    // Hook handlers

    /**
     * @inheritdoc IHookReceiver
     */
    function beforeAction(
        address _silo,
        uint256 _action,
        bytes calldata _inputAndOutput
    ) public override {
        if (_silo != responderSilo) return;

        if (emergencyPause) revert ResponderHook_Paused();

        if (Hook.matchAction(_action, Hook.WITHDRAW | Hook.COLLATERAL_TOKEN)) {
            _beforeWithdraw(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.BORROW)) {
            _beforeBorrow(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.LIQUIDATION)) {
            _beforeLiquidation(_inputAndOutput);
        }
    }

    /**
     * @dev Handle withdrawals from responder by pulling from controller if needed
     * @param _inputAndOutput Encoded withdrawal data
     */
    function _beforeWithdraw(bytes calldata _inputAndOutput) internal {
        Hook.BeforeWithdrawInput memory input = Hook.beforeWithdrawDecode(
            _inputAndOutput
        );

        // Skip if it's the controller withdrawing (to avoid recursion)
        if (input.owner == controllerSilo) return;

        uint256 withdrawAmount = input.assets;
        if (withdrawAmount == 0) {
            // For share-based withdrawals, estimate the assets
            withdrawAmount = ISilo(responderSilo).previewRedeem(input.shares);
        }

        // Check if we need to pull from controller
        _ensureSufficientLiquidity(withdrawAmount);

        // Reduce real assets tracker
        if (realAssets >= withdrawAmount) {
            realAssets -= withdrawAmount;
        } else {
            realAssets = 0;
        }

        emit WithdrawalProcessed(input.owner, withdrawAmount, input.shares);
    }

    /**
     * @dev Handle borrows by ensuring sufficient liquidity
     * @param _inputAndOutput Encoded borrow data
     */
    function _beforeBorrow(bytes calldata _inputAndOutput) internal {
        Hook.BeforeBorrowInput memory input = Hook.beforeBorrowDecode(
            _inputAndOutput
        );

        // Ensure we have the liquidity
        _ensureSufficientLiquidity(input.assets);

        emit BorrowProcessed(input.borrower, input.assets);
    }

    /**
     * @dev Handle liquidations by pulling all from controller
     */
    function _beforeLiquidation(bytes calldata _inputAndOutput) internal {
        // Pull everything from controller to handle liquidation
        _pullAllFromController();
    }

    /**
     * @inheritdoc IHookReceiver
     */
    function afterAction(
        address _silo,
        uint256 _action,
        bytes calldata _inputAndOutput
    ) public override {
        if (_silo != responderSilo) return;

        if (emergencyPause) return;

        if (Hook.matchAction(_action, Hook.DEPOSIT | Hook.COLLATERAL_TOKEN)) {
            _afterDeposit(_inputAndOutput);
        }
    }

    // Implementation details

    /**
     * @dev Handle deposits to the responder
     * @param _inputAndOutput Encoded deposit data
     */
    function _afterDeposit(bytes calldata _inputAndOutput) internal {
        Hook.AfterDepositInput memory input = Hook.afterDepositDecode(
            _inputAndOutput
        );

        if (input.receiver == controllerSilo) {
            // This is a virtual deposit from controller
            virtualAssets += input.receivedAssets;
            emit ControllerDepositReceived(
                input.receivedAssets,
                input.mintedShares
            );
        } else {
            // This is a direct deposit from a user
            realAssets += input.receivedAssets;
            emit DirectDepositReceived(
                input.receiver,
                input.receivedAssets,
                input.mintedShares
            );

            // Forward deposit to controller
            _forwardDepositToController(input.receivedAssets);
        }
    }

    /**
     * @dev Forward user deposits to the controller
     * @param _amount Amount to forward
     */
    function _forwardDepositToController(uint256 _amount) internal {
        if (_amount == 0) return;

        address asset = ISilo(responderSilo).asset();

        // Approve controller to pull tokens
        ISilo(responderSilo).callOnBehalfOfSilo(
            asset,
            0,
            ISilo.CallType.Call,
            abi.encodeWithSelector(
                IERC20.approve.selector,
                controllerSilo,
                _amount
            )
        );

        // Deposit to controller
        try
            ISilo(responderSilo).callOnBehalfOfSilo(
                controllerSilo,
                0,
                ISilo.CallType.Call,
                abi.encodeWithSelector(
                    ISilo.deposit.selector,
                    _amount,
                    responderSilo,
                    uint8(ISilo.CollateralType.Collateral)
                )
            )
        {
            // Successfully forwarded
        } catch {
            // Failed to forward - keep locally
        }
    }

    /**
     * @dev Ensure responder has enough liquidity for an operation
     * @param _amountNeeded Amount of assets needed
     */
    function _ensureSufficientLiquidity(uint256 _amountNeeded) internal {
        if (_amountNeeded == 0) return;

        address asset = ISilo(responderSilo).asset();
        uint256 localBalance = IERC20(asset).balanceOf(responderSilo);

        // Include buffer in calculations
        uint256 withBuffer = _amountNeeded +
            ((_amountNeeded * minLiquidityBuffer) / 100);

        if (localBalance >= withBuffer) return;

        // We need to pull from controller
        uint256 shortfall = withBuffer - localBalance;

        // Calculate controller position
        uint256 controllerShares = ISilo(controllerSilo).balanceOf(
            responderSilo
        );

        if (controllerShares == 0) {
            // We don't have controller position, yet need liquidity
            if (localBalance < _amountNeeded) {
                revert ResponderHook_InsufficientLiquidity();
            }
            return;
        }

        // Calculate max we can pull
        uint256 maxWithdrawable = ISilo(controllerSilo).previewRedeem(
            controllerShares
        );

        if (maxWithdrawable < shortfall) {
            // Can't withdraw enough - if we can at least cover the needed amount (without buffer)
            if (localBalance + maxWithdrawable < _amountNeeded) {
                revert ResponderHook_InsufficientLiquidity();
            }

            // Pull everything we can
            shortfall = maxWithdrawable;
        }

        // Calculate shares to withdraw
        uint256 sharesToWithdraw = (controllerShares * shortfall) /
            maxWithdrawable;

        if (sharesToWithdraw == 0) return;

        // Withdraw from controller
        try
            ISilo(responderSilo).callOnBehalfOfSilo(
                controllerSilo,
                0,
                ISilo.CallType.Call,
                abi.encodeWithSelector(
                    ISilo.redeem.selector,
                    sharesToWithdraw,
                    responderSilo,
                    responderSilo,
                    uint8(ISilo.CollateralType.Collateral)
                )
            )
        {
            // Successfully pulled from controller

            // Adjust tracking
            uint256 newBalance = IERC20(asset).balanceOf(responderSilo);
            uint256 received = newBalance - localBalance;

            // Update virtual vs real balance
            if (virtualAssets >= received) {
                virtualAssets -= received;
                realAssets += received;
            } else {
                realAssets += virtualAssets;
                virtualAssets = 0;
            }

            emit PositionPulledFromController(received, sharesToWithdraw);
        } catch {
            // Failed to pull - if we don't have enough without it, revert
            if (localBalance < _amountNeeded) {
                revert ResponderHook_InsufficientLiquidity();
            }
        }
    }

    /**
     * @dev Pull all position from controller
     */
    function _pullAllFromController() internal {
        uint256 controllerShares = ISilo(controllerSilo).balanceOf(
            responderSilo
        );

        if (controllerShares == 0) return;

        address asset = ISilo(responderSilo).asset();
        uint256 localBalanceBefore = IERC20(asset).balanceOf(responderSilo);

        // Withdraw all from controller
        try
            ISilo(responderSilo).callOnBehalfOfSilo(
                controllerSilo,
                0,
                ISilo.CallType.Call,
                abi.encodeWithSelector(
                    ISilo.redeem.selector,
                    controllerShares,
                    responderSilo,
                    responderSilo,
                    uint8(ISilo.CollateralType.Collateral)
                )
            )
        {
            // Successfully pulled all
            uint256 localBalanceAfter = IERC20(asset).balanceOf(responderSilo);
            uint256 received = localBalanceAfter - localBalanceBefore;

            // Update tracking
            realAssets += virtualAssets;
            virtualAssets = 0;

            emit PositionPulledFromController(received, controllerShares);
        } catch {
            // Failed to pull - this is an edge case for liquidation
            // We should still try to proceed with local assets
        }
    }

    // View functions

    /**
     * @notice Get total virtual assets
     */
    function getVirtualAssetBalance() external view returns (uint256) {
        return virtualAssets;
    }

    /**
     * @notice Get total real assets
     */
    function getRealAssetBalance() external view returns (uint256) {
        return realAssets;
    }

    /**
     * @notice Check if responder can handle a withdrawal or borrow
     * @param _amount Amount to check
     */
    function canHandle(uint256 _amount) external view returns (bool) {
        address asset = ISilo(responderSilo).asset();
        uint256 localBalance = IERC20(asset).balanceOf(responderSilo);

        if (localBalance >= _amount) return true;

        // Calculate how much we can pull from controller
        uint256 controllerShares = ISilo(controllerSilo).balanceOf(
            responderSilo
        );
        if (controllerShares == 0) return false;

        uint256 maxWithdrawable = ISilo(controllerSilo).previewRedeem(
            controllerShares
        );

        return localBalance + maxWithdrawable >= _amount;
    }
}
