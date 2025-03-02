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
 * @title EnhancedControllerHook
 * @notice Hook for the controller silo that manages propagation of deposits to responder silos
 * and serves as a registry for the shared asset system.
 */
contract ControllerSiloHook is GaugeHookReceiver {
    address public controllerSilo;
    address[] public responderSilos;
    address[] public responderHooks;

    // Track virtual deposits and shares for each responder
    mapping(address => uint256) public virtualDeposits;
    mapping(address => uint256) public virtualShares;

    // Track interest accrual for each responder
    mapping(address => uint256) public lastInterestTimestamp;

    // Map responder silos to their hooks
    mapping(address => address) public responderToHook;

    // Map all silos to their asset
    mapping(address => address) public siloAsset;

    // Safety mechanisms
    bool public emergencyPause;
    uint256 public maxPropagationRatio = 80; // 80% - keep 20% liquidity buffer by default

    event VirtualDepositCreated(
        address indexed responderSilo,
        uint256 assets,
        uint256 shares
    );
    event VirtualDepositCancelled(
        address indexed responderSilo,
        uint256 assets,
        uint256 shares
    );
    event InterestAccrued(address indexed responderSilo, uint256 amount);
    event ResponderAdded(
        address indexed responderSilo,
        address indexed responderHook
    );
    event EmergencyPauseSet(bool paused);
    event MaxPropagationRatioSet(uint256 ratio);

    error ControllerHook_Paused();
    error ControllerHook_MaxRatioExceeded();
    error ControllerHook_OperationFailed();
    error ControllerHook_NotResponder();
    error ControllerHook_ZeroAddress();
    error ControllerHook_AssetMismatch();
    error ControllerHook_AlreadyRegistered();
    error ControllerHook_OnlyOwner();

    /**
     * @dev Initializer for the controller hook
     * @param _siloConfig The SiloConfig for the marketplace
     * @param _data Initialization data (owner, asset)
     */
    function initialize(
        ISiloConfig _siloConfig,
        bytes calldata _data
    ) external override initializer {
        (address owner, address asset) = abi.decode(_data, (address, address));

        // Initialize base hook receiver and gauge hook receiver
        BaseHookReceiver.__BaseHookReceiver_init(_siloConfig);
        GaugeHookReceiver.__GaugeHookReceiver_init(owner);

        // Identify which silo in the config is using our asset
        (address silo0, address silo1) = _siloConfig.getSilos();
        if (ISilo(silo0).asset() == asset) {
            controllerSilo = silo0;
        } else if (ISilo(silo1).asset() == asset) {
            controllerSilo = silo1;
        } else {
            revert("Invalid asset for silo");
        }

        // Store asset for controller silo
        siloAsset[controllerSilo] = asset;

        // Configure hooks
        (uint256 hooksBefore, uint256 hooksAfter) = _hookReceiverConfig(
            controllerSilo
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

        _setHookConfig(controllerSilo, hooksBefore, hooksAfter);
    }

    // Admin functions

    /**
     * @notice Register a new responder silo and its hook
     * @param _responderSilo Address of the responder silo
     * @param _responderHook Address of the responder silo hook
     */
    function registerResponderSilo(
        address _responderSilo,
        address _responderHook
    ) external onlyOwner {
        if (_responderSilo == address(0) || _responderHook == address(0)) {
            revert ControllerHook_ZeroAddress();
        }

        // Get responder silo asset
        address responderAsset = ISilo(_responderSilo).asset();
        address controllerAsset = siloAsset[controllerSilo];

        // Verify it's a valid silo with the same asset
        if (responderAsset != controllerAsset) {
            revert ControllerHook_AssetMismatch();
        }

        // Store asset for responder silo
        siloAsset[_responderSilo] = responderAsset;

        // Check if already registered
        for (uint i = 0; i < responderSilos.length; i++) {
            if (responderSilos[i] == _responderSilo) {
                // Update hook if different
                if (responderHooks[i] != _responderHook) {
                    responderHooks[i] = _responderHook;
                    responderToHook[_responderSilo] = _responderHook;
                }
                return;
            }
        }

        // Add responder to arrays
        responderSilos.push(_responderSilo);
        responderHooks.push(_responderHook);
        responderToHook[_responderSilo] = _responderHook;

        emit ResponderAdded(_responderSilo, _responderHook);
    }

    /**
     * @notice Set emergency pause
     * @param _paused Whether to pause operations
     */
    function setEmergencyPause(bool _paused) external onlyOwner {
        emergencyPause = _paused;
        emit EmergencyPauseSet(_paused);
    }

    /**
     * @notice Set maximum propagation ratio (in percentage)
     * @param _ratio New propagation ratio (1-100)
     */
    function setMaxPropagationRatio(uint256 _ratio) external onlyOwner {
        require(_ratio > 0 && _ratio <= 100, "Ratio must be between 1-100");
        maxPropagationRatio = _ratio;
        emit MaxPropagationRatioSet(_ratio);
    }

    // View functions

    /**
     * @notice Get the controller's asset
     */
    function getAsset() external view returns (address) {
        return siloAsset[controllerSilo];
    }

    /**
     * @notice Get number of registered responder silos
     */
    function getResponderCount() external view returns (uint256) {
        return responderSilos.length;
    }

    /**
     * @notice Get all responder silos
     */
    function getAllResponders() external view returns (address[] memory) {
        return responderSilos;
    }

    /**
     * @notice Get total virtual deposits across all responders
     */
    function getTotalVirtualDeposits() external view returns (uint256 total) {
        for (uint i = 0; i < responderSilos.length; i++) {
            total += virtualDeposits[responderSilos[i]];
        }
        return total;
    }

    /**
     * @notice Get distribution of asset across controller and responders
     * @return controllerBalance Real balance in controller
     * @return virtualBalance Virtual balance across responders
     * @return responderDirectBalance Direct balance in responders
     */
    function getAssetDistribution()
        external
        view
        returns (
            uint256 controllerBalance,
            uint256 virtualBalance,
            uint256 responderDirectBalance
        )
    {
        address asset = siloAsset[controllerSilo];
        controllerBalance = IERC20(asset).balanceOf(controllerSilo);

        for (uint i = 0; i < responderSilos.length; i++) {
            address responder = responderSilos[i];
            address responderHook = responderHooks[i];

            // Add virtual balance
            virtualBalance += virtualDeposits[responder];

            // Try to get real balance through the hook if possible
            try IResponderHook(responderHook).getRealAssetBalance() returns (
                uint256 rBalance
            ) {
                responderDirectBalance += rBalance;
            } catch {}
        }
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
        if (_silo != controllerSilo) return;

        if (emergencyPause) revert ControllerHook_Paused();

        if (Hook.matchAction(_action, Hook.WITHDRAW | Hook.COLLATERAL_TOKEN)) {
            _beforeWithdraw(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.BORROW)) {
            _beforeBorrow(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.LIQUIDATION)) {
            _beforeLiquidation(_inputAndOutput);
        }
    }

    /**
     * @inheritdoc IHookReceiver
     */
    function afterAction(
        address _silo,
        uint256 _action,
        bytes calldata _inputAndOutput
    ) public override {
        if (_silo != controllerSilo) return;

        if (emergencyPause) return;

        if (Hook.matchAction(_action, Hook.DEPOSIT | Hook.COLLATERAL_TOKEN)) {
            _afterDeposit(_inputAndOutput);
        }
    }

    // Implementation details

    /**
     * @dev Handle deposit propagation after a deposit to the controller
     * @param _inputAndOutput Encoded deposit data
     */
    function _afterDeposit(bytes calldata _inputAndOutput) internal {
        Hook.AfterDepositInput memory input = Hook.afterDepositDecode(
            _inputAndOutput
        );

        // Accrue interest before propagation
        _accrueInterestForAll();

        // Calculate how much to propagate (respecting max ratio)
        uint256 totalDeposit = input.receivedAssets;
        uint256 maxToPropagate = (totalDeposit * maxPropagationRatio) / 100;

        // Skip propagation if amount is too small
        if (maxToPropagate == 0) return;

        // Calculate how much each responder gets
        uint256 responderCount = responderSilos.length;
        if (responderCount == 0) return;

        uint256 amountPerResponder = maxToPropagate / responderCount;
        if (amountPerResponder == 0) return;

        // Propagate to each responder
        for (uint i = 0; i < responderCount; i++) {
            address responderSilo = responderSilos[i];

            try this._propagateDeposit(responderSilo, amountPerResponder) {
                // Successfully propagated
            } catch {
                // Failed to propagate - could add recovery logic here
            }
        }
    }

    /**
     * @dev Execute deposit propagation to a responder
     * @param _responderSilo Responder silo address
     * @param _amount Amount to propagate
     */
    function _propagateDeposit(
        address _responderSilo,
        uint256 _amount
    ) external {
        require(msg.sender == address(this), "External calls not allowed");

        address asset = siloAsset[controllerSilo];

        // Approve responder to pull tokens
        ISilo(controllerSilo).callOnBehalfOfSilo(
            asset,
            0,
            ISilo.CallType.Call,
            abi.encodeWithSelector(
                IERC20.approve.selector,
                _responderSilo,
                _amount
            )
        );

        // Check shares before deposit
        uint256 sharesBefore = ISilo(_responderSilo).balanceOf(controllerSilo);

        // Deposit to responder
        ISilo(controllerSilo).callOnBehalfOfSilo(
            _responderSilo,
            0,
            ISilo.CallType.Call,
            abi.encodeWithSelector(
                ISilo.deposit.selector,
                _amount,
                controllerSilo,
                uint8(ISilo.CollateralType.Collateral)
            )
        );

        // Calculate shares received
        uint256 sharesAfter = ISilo(_responderSilo).balanceOf(controllerSilo);
        uint256 newShares = sharesAfter - sharesBefore;

        // Update tracking
        virtualDeposits[_responderSilo] += _amount;
        virtualShares[_responderSilo] += newShares;
        lastInterestTimestamp[_responderSilo] = block.timestamp;

        emit VirtualDepositCreated(_responderSilo, _amount, newShares);
    }

    /**
     * @dev Handle withdrawal by cancelling virtual deposits
     * @param _inputAndOutput Encoded withdrawal data
     */
    function _beforeWithdraw(bytes calldata _inputAndOutput) internal {
        Hook.BeforeWithdrawInput memory input = Hook.beforeWithdrawDecode(
            _inputAndOutput
        );

        uint256 withdrawAmount = input.assets;
        if (withdrawAmount == 0) {
            // For share-based withdrawals, estimate the assets
            withdrawAmount = ISilo(controllerSilo).previewRedeem(input.shares);
        }

        // Accrue interest before cancelling
        _accrueInterestForAll();

        // Calculate what proportion of virtual deposits to cancel
        _cancelVirtualDepositsProportionally(withdrawAmount);
    }

    /**
     * @dev Handle borrow by cancelling virtual deposits
     * @param _inputAndOutput Encoded borrow data
     */
    function _beforeBorrow(bytes calldata _inputAndOutput) internal {
        Hook.BeforeBorrowInput memory input = Hook.beforeBorrowDecode(
            _inputAndOutput
        );

        // Accrue interest before cancelling
        _accrueInterestForAll();

        // Cancel deposits to free up liquidity
        _cancelVirtualDepositsProportionally(input.assets);
    }

    /**
     * @dev Handle liquidation by cancelling all virtual deposits
     * @param _inputAndOutput Encoded liquidation data
     */
    function _beforeLiquidation(bytes calldata _inputAndOutput) internal {
        // For liquidations, cancel all virtual deposits
        _accrueInterestForAll();
        _cancelAllVirtualDeposits();
    }

    /**
     * @dev Calculate and accrue interest for all responders
     */
    function _accrueInterestForAll() internal {
        for (uint i = 0; i < responderSilos.length; i++) {
            address responderSilo = responderSilos[i];

            // Skip if no virtual deposits
            if (virtualDeposits[responderSilo] == 0) continue;

            // Calculate interest
            _accrueInterestForResponder(responderSilo);
        }
    }

    /**
     * @dev Accrue interest for a specific responder
     * @param _responderSilo Responder silo address
     */
    function _accrueInterestForResponder(address _responderSilo) internal {
        // Skip if no shares
        if (virtualShares[_responderSilo] == 0) return;

        // Get current value of shares
        uint256 currentAssetValue = ISilo(_responderSilo).previewRedeem(
            virtualShares[_responderSilo]
        );

        // If value increased, record the interest
        if (currentAssetValue > virtualDeposits[_responderSilo]) {
            uint256 interestAccrued = currentAssetValue -
                virtualDeposits[_responderSilo];
            virtualDeposits[_responderSilo] = currentAssetValue;

            emit InterestAccrued(_responderSilo, interestAccrued);
        }

        lastInterestTimestamp[_responderSilo] = block.timestamp;
    }

    /**
     * @dev Cancel virtual deposits proportionally to the amount needed
     * @param _amountNeeded Amount of assets needed
     */
    function _cancelVirtualDepositsProportionally(
        uint256 _amountNeeded
    ) internal {
        if (_amountNeeded == 0) return;

        // Calculate total virtual deposits
        uint256 totalVirtual = 0;
        for (uint i = 0; i < responderSilos.length; i++) {
            totalVirtual += virtualDeposits[responderSilos[i]];
        }

        if (totalVirtual == 0) return;

        // If we need more than available, cancel everything
        if (_amountNeeded >= totalVirtual) {
            _cancelAllVirtualDeposits();
            return;
        }

        // Otherwise cancel proportionally
        for (uint i = 0; i < responderSilos.length; i++) {
            address responderSilo = responderSilos[i];
            uint256 responderDeposit = virtualDeposits[responderSilo];

            if (responderDeposit == 0) continue;

            // Calculate proportion to cancel
            uint256 amountToCancel = (_amountNeeded * responderDeposit) /
                totalVirtual;
            if (amountToCancel == 0) continue;

            // Calculate shares to withdraw
            uint256 sharesToCancel = 0;
            if (virtualDeposits[responderSilo] > 0) {
                sharesToCancel =
                    (virtualShares[responderSilo] * amountToCancel) /
                    virtualDeposits[responderSilo];
            }

            if (sharesToCancel == 0) continue;

            _cancelVirtualDeposit(
                responderSilo,
                sharesToCancel,
                amountToCancel
            );
        }
    }

    /**
     * @dev Cancel all virtual deposits across all responders
     */
    function _cancelAllVirtualDeposits() internal {
        for (uint i = 0; i < responderSilos.length; i++) {
            address responderSilo = responderSilos[i];

            uint256 shares = virtualShares[responderSilo];
            uint256 deposits = virtualDeposits[responderSilo];

            if (shares > 0) {
                _cancelVirtualDeposit(responderSilo, shares, deposits);
            }
        }
    }

    /**
     * @dev Cancel a specific amount of virtual deposit from a responder
     * @param _responderSilo Responder silo address
     * @param _shares Shares to cancel
     * @param _expectedAssets Expected assets to receive
     */
    function _cancelVirtualDeposit(
        address _responderSilo,
        uint256 _shares,
        uint256 _expectedAssets
    ) internal {
        if (_shares == 0) return;

        // Ensure we don't withdraw more shares than we have
        uint256 actualShares = ISilo(_responderSilo).balanceOf(controllerSilo);
        if (_shares > actualShares) {
            _shares = actualShares;
        }

        try
            ISilo(controllerSilo).callOnBehalfOfSilo(
                _responderSilo,
                0,
                ISilo.CallType.Call,
                abi.encodeWithSelector(
                    ISilo.redeem.selector,
                    _shares,
                    controllerSilo,
                    controllerSilo,
                    uint8(ISilo.CollateralType.Collateral)
                )
            )
        returns (bool success, bytes memory result) {
            // Successfully cancelled the deposit

            // Update tracking data
            if (virtualShares[_responderSilo] > _shares) {
                virtualShares[_responderSilo] -= _shares;
            } else {
                virtualShares[_responderSilo] = 0;
            }

            if (virtualDeposits[_responderSilo] > _expectedAssets) {
                virtualDeposits[_responderSilo] -= _expectedAssets;
            } else {
                virtualDeposits[_responderSilo] = 0;
            }

            emit VirtualDepositCancelled(
                _responderSilo,
                _expectedAssets,
                _shares
            );
        } catch {
            // Handle failure - could try again with smaller amount or log error
        }
    }
}

/**
 * @dev Interface for responder hook functions used by the controller
 */
interface IResponderHook {
    function getVirtualAssetBalance() external view returns (uint256);
    function getRealAssetBalance() external view returns (uint256);
}
