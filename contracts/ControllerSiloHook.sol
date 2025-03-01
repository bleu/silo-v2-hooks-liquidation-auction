// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IHookReceiver} from "silo-contracts-v2/silo-core/contracts/interfaces/IHookReceiver.sol";
import {ISiloConfig} from "silo-contracts-v2/silo-core/contracts/interfaces/ISiloConfig.sol";
import {ISilo} from "silo-contracts-v2/silo-core/contracts/interfaces/ISilo.sol";
import {IERC20} from "openzeppelin5/token/ERC20/IERC20.sol";

import {Hook} from "silo-contracts-v2/silo-core/contracts/lib/Hook.sol";
import {BaseHookReceiver} from "silo-contracts-v2/silo-core/contracts/utils/hook-receivers/_common/BaseHookReceiver.sol";
import {GaugeHookReceiver} from "silo-contracts-v2/silo-core/contracts/utils/hook-receivers/gauge/GaugeHookReceiver.sol";
import {PartialLiquidation} from "silo-contracts-v2/silo-core/contracts/utils/hook-receivers/liquidation/PartialLiquidation.sol";

// Interface for the responder hook
interface IResponderSiloHook {
    function depositReceivedAssets() external;
}

/// @dev Example of hook, that prevents borrowing asset. Note: borrowing same asset is still available.
contract ControllerSiloHook is GaugeHookReceiver, PartialLiquidation {
    address public controllerSilo;
    address[] public responderSilos;
    address[] public responderHooks;

    event Log(string message, uint256 value);
    event Log(string message, address value);
    event Log(string message, bytes value);

    error ControllerHook_WrongSilo();

    /// @dev this method is mandatory and it has to initialize inherited contracts
    function initialize(
        ISiloConfig _siloConfig,
        bytes calldata _data
    ) external override initializer {
        // do not remove initialization lines, if you want fully compatible functionality
        (address owner, address sharedAsset) = abi.decode(
            _data,
            (address, address)
        );

        // initialize hook with SiloConfig address.
        // SiloConfig is the source of all information about Silo markets you are extending.
        BaseHookReceiver.__BaseHookReceiver_init(_siloConfig);

        // initialize GaugeHookReceiver. Owner can set "gauge" aka incentives contract for a Silo retroactively.
        GaugeHookReceiver.__GaugeHookReceiver_init(owner);

        __ControllerHook_init(_siloConfig, sharedAsset);
    }

    function __ControllerHook_init(
        ISiloConfig _siloConfig,
        address sharedAsset
    ) internal {
        (address silo0, address silo1) = _siloConfig.getSilos();
        address controllerSiloCached;

        if (ISilo(silo0).asset() == sharedAsset) controllerSiloCached = silo0;
        else if (ISilo(silo1).asset() == sharedAsset)
            controllerSiloCached = silo1;
        else revert ControllerHook_WrongSilo();

        controllerSilo = controllerSiloCached;

        // fetch current setup in case there were some hooks already implemented
        (uint256 hooksBefore, uint256 hooksAfter) = _hookReceiverConfig(
            controllerSiloCached
        );

        // your code here
        //
        // It is recommended to use `addAction` and `removeAction` when working with hook.
        // It is expected that hooks bitmap will store settings for multiple hooks and utility
        // functions like `addAction` and `removeAction` will make sure to not override
        // other hooks' settings.
        hooksAfter = Hook.addAction(
            hooksAfter,
            Hook.DEPOSIT | Hook.COLLATERAL_TOKEN
        );

        hooksAfter = Hook.addAction(
            hooksAfter,
            Hook.WITHDRAW | Hook.COLLATERAL_TOKEN
        );

        hooksBefore = Hook.addAction(
            hooksBefore,
            Hook.DEPOSIT | Hook.COLLATERAL_TOKEN
        );

        hooksBefore = Hook.addAction(
            hooksBefore,
            Hook.WITHDRAW | Hook.COLLATERAL_TOKEN
        );

        _setHookConfig(controllerSiloCached, hooksBefore, hooksAfter);
    }

    // We assume no liquidity will have been deployed before all the responder silos are registered
    function registerResponderSilo(address _responderSilo) external {
        responderSilos.push(_responderSilo);
    }

    // Register a responder hook
    function registerResponderHook(address _responderHook) external {
        responderHooks.push(_responderHook);
    }

    /// @inheritdoc IHookReceiver
    function beforeAction(
        address _silo,
        uint256 _action,
        bytes calldata _inputAndOutput
    ) public override {
        if (_silo != controllerSilo) {
            return;
        }

        if (Hook.matchAction(_action, Hook.BORROW)) {
            _beforeBorrow(_inputAndOutput);
        } else if (
            Hook.matchAction(_action, Hook.DEPOSIT | Hook.COLLATERAL_TOKEN)
        ) {
            _beforeDeposit(_inputAndOutput);
        } else if (
            Hook.matchAction(_action, Hook.WITHDRAW | Hook.COLLATERAL_TOKEN)
        ) {
            _beforeWithdraw(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.LIQUIDATION)) {
            _beforeLiquidate(_inputAndOutput);
        } else {
            revert RequestNotSupported();
        }
    }

    /// @inheritdoc IHookReceiver
    function afterAction(
        address _silo,
        uint256 _action,
        bytes calldata _inputAndOutput
    ) public override(GaugeHookReceiver, IHookReceiver) {
        // Skip the GaugeHookReceiver.afterAction call that's causing the error
        // GaugeHookReceiver.afterAction(_silo, _action, _inputAndOutput);

        if (_silo != controllerSilo) {
            return;
        }

        if (Hook.matchAction(_action, Hook.BORROW)) {
            _afterBorrow(_inputAndOutput);
        } else if (
            Hook.matchAction(_action, Hook.DEPOSIT | Hook.COLLATERAL_TOKEN)
        ) {
            _afterDeposit(_inputAndOutput);
        } else if (
            Hook.matchAction(_action, Hook.WITHDRAW | Hook.COLLATERAL_TOKEN)
        ) {
            _afterWithdraw(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.LIQUIDATION)) {
            _afterLiquidate(_inputAndOutput);
        } else {
            revert RequestNotSupported();
        }
    }

    function _beforeDeposit(bytes calldata _inputAndOutput) internal {
        // No-op. We don't need to do anything before a deposit.
    }

    function _afterDeposit(bytes calldata _inputAndOutput) internal {
        Hook.AfterDepositInput memory input = Hook.afterDepositDecode(
            _inputAndOutput
        );

        address collateralToken = ISilo(controllerSilo).asset();
        uint256 assets = input.assets;
        require(assets > 0, "Assets must be greater than 0");
        require(
            IERC20(collateralToken).balanceOf(address(controllerSilo)) >=
                assets,
            "Insufficient balance of collateral token"
        );

        // For each responder silo, we'll create a "virtual" deposit
        // The controller silo keeps the actual assets, but we temporarily transfer them
        // to each responder silo to create shares
        for (uint256 i = 0; i < responderSilos.length; i++) {
            emit Log("Transferred assets to responder", assets);
            emit Log("Responder silo", responderSilos[i]);

            // ensure the responder silo has allowance for the collateral token
            ISilo(controllerSilo).callOnBehalfOfSilo(
                collateralToken,
                0,
                ISilo.CallType.Call,
                abi.encodeWithSelector(
                    IERC20.approve.selector,
                    responderSilos[i],
                    assets
                )
            );

            // Now, deposit the assets into the responder silo
            // We need to call deposit directly on the responder silo
            ISilo(controllerSilo).callOnBehalfOfSilo(
                responderSilos[i],
                0,
                ISilo.CallType.Call,
                abi.encodeWithSelector(
                    bytes4(keccak256("deposit(uint256,address,uint8)")),
                    assets,
                    controllerSilo,
                    ISilo.CollateralType.Collateral
                )
            );

            emit Log("Deposited assets into responder silo", assets);
        }
    }

    function _beforeWithdraw(bytes calldata _inputAndOutput) internal {
        emit Log("Before withdraw", _inputAndOutput);
        Hook.BeforeWithdrawInput memory input = Hook.beforeWithdrawDecode(
            _inputAndOutput
        );
        // since we have shares from the responder silos, we need to burn them. So we send
        // the collateral token to each responder silo to burn the shares. And it will be
        // transferred back to the controller silo after the shares are burned.
        for (uint256 i = 0; i < responderSilos.length; i++) {
            ISilo(controllerSilo).callOnBehalfOfSilo(
                ISilo(controllerSilo).asset(),
                0,
                ISilo.CallType.Call,
                abi.encodeWithSelector(
                    IERC20.transfer.selector,
                    responderSilos[i],
                    input.assets
                )
            );

            ISilo(controllerSilo).callOnBehalfOfSilo(
                responderSilos[i],
                0,
                ISilo.CallType.Call,
                abi.encodeWithSelector(
                    ISilo.withdraw.selector,
                    input.assets,
                    controllerSilo,
                    controllerSilo,
                    ISilo.CollateralType.Collateral
                )
            );
        }
    }

    function _afterWithdraw(bytes calldata _inputAndOutput) internal {
        emit Log("After withdraw", _inputAndOutput);
    }

    function _beforeBorrow(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function _beforeLiquidate(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function _afterBorrow(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function _afterLiquidate(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function getHookConfig(
        address _silo
    ) public view returns (uint256 hooksBefore, uint256 hooksAfter) {
        return _hookReceiverConfig(_silo);
    }
}
