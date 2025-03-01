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

/// @dev Example of hook, that prevents borrowing asset. Note: borrowing same asset is still available.
contract ResponderSiloHook is GaugeHookReceiver, PartialLiquidation {
    address public siloResponder;
    address public controllerSilo;

    error ResponderHook_WrongSilo();

    /// @dev this method is mandatory and it has to initialize inherited contracts
    function initialize(
        ISiloConfig _siloConfig,
        bytes calldata _data
    ) external override initializer {
        // do not remove initialization lines, if you want fully compatible functionality
        (
            address owner,
            address sharedAsset,
            address incomingControllerSilo
        ) = abi.decode(_data, (address, address, address));

        controllerSilo = incomingControllerSilo;
        // initialize hook with SiloConfig address.
        // SiloConfig is the source of all information about Silo markets you are extending.
        BaseHookReceiver.__BaseHookReceiver_init(_siloConfig);

        // initialize GaugeHookReceiver. Owner can set "gauge" aka incentives contract for a Silo retroactively.
        GaugeHookReceiver.__GaugeHookReceiver_init(owner);

        __ResponderHook_init(_siloConfig, sharedAsset);
    }

    function __ResponderHook_init(
        ISiloConfig _siloConfig,
        address sharedAsset
    ) internal {
        (address silo0, address silo1) = _siloConfig.getSilos();
        address siloResponderCached;

        if (ISilo(silo0).asset() == sharedAsset) siloResponderCached = silo0;
        else if (ISilo(silo1).asset() == sharedAsset)
            siloResponderCached = silo1;
        else revert ResponderHook_WrongSilo();

        siloResponder = siloResponderCached;

        // fetch current setup in case there were some hooks already implemented
        (uint256 hooksBefore, uint256 hooksAfter) = _hookReceiverConfig(
            siloResponderCached
        );

        // It is recommended to use `addAction` and `removeAction` when working with hook.
        // It is expected that hooks bitmap will store settings for multiple hooks and utility
        // functions like `addAction` and `removeAction` will make sure to not override
        // other hooks' settings.
        hooksAfter = Hook.addAction(hooksAfter, Hook.DEPOSIT);
        _setHookConfig(siloResponderCached, hooksBefore, hooksAfter);
    }

    /// @inheritdoc IHookReceiver
    function beforeAction(
        address _silo,
        uint256 _action,
        bytes calldata _inputAndOutput
    ) public override {
        if (_silo != siloResponder) {
            return;
        }

        if (Hook.matchAction(_action, Hook.BORROW)) {
            _beforeBorrow(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.DEPOSIT)) {
            _beforeDeposit(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.WITHDRAW)) {
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
        GaugeHookReceiver.afterAction(_silo, _action, _inputAndOutput);

        if (_silo != siloResponder) {
            return;
        }

        if (Hook.matchAction(_action, Hook.BORROW)) {
            _afterBorrow(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.DEPOSIT)) {
            _afterDeposit(_inputAndOutput);
        } else if (Hook.matchAction(_action, Hook.WITHDRAW)) {
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

        if (input.receiver == controllerSilo) {
            // if the receiver is the controller, we'll just transfer the collateral back to them
            // find out what the collateral token is

            ISilo silo = ISilo(siloResponder);

            address collateralToken = silo.asset();

            silo.callOnBehalfOfSilo(
                collateralToken,
                0,
                ISilo.CallType.Call,
                abi.encodeWithSelector(
                    IERC20.transfer.selector,
                    controllerSilo,
                    input.receivedAssets
                )
            );
        }
    }

    function _beforeWithdraw(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function _beforeBorrow(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function _beforeLiquidate(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function _afterWithdraw(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function _afterBorrow(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function _afterLiquidate(bytes calldata _inputAndOutput) internal {
        // TODO: implement
    }

    function hookReceiverConfig(
        address _silo
    )
        external
        view
        override(BaseHookReceiver, IHookReceiver)
        returns (uint24 hooksBefore, uint24 hooksAfter)
    {
        (hooksBefore, hooksAfter) = _hookReceiverConfig(_silo);
    }
}
