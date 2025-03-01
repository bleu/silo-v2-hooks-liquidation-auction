// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {IERC20Metadata} from "silo-core-v2/interfaces/IShareToken.sol";

import {ISiloConfig} from "silo-core-v2/interfaces/ISiloConfig.sol";
import {ISilo} from "silo-core-v2/interfaces/ISilo.sol";
import {ArbitrumLib} from "./ArbitrumLib.sol";
import {ControllerSiloHook} from "../../contracts/ControllerSiloHook.sol";
import {ResponderSiloHook} from "../../contracts/ResponderSiloHook.sol";

contract Labels is Test {
    function _setLabels(ISiloConfig _siloConfig) internal virtual {
        vm.label(address(ArbitrumLib.SILO_DEPLOYER), "SILO_DEPLOYER");
        vm.label(
            address(ArbitrumLib.CHAINLINK_ETH_USD_AGREGATOR),
            "CHAINLINK_ETH_USD_AGREGATOR"
        );
        vm.label(address(ArbitrumLib.WETH), "WETH");
        vm.label(address(ArbitrumLib.USDC), "USDC");

        vm.label(address(_siloConfig), string.concat("siloConfig"));

        (address silo0, address silo1) = _siloConfig.getSilos();

        _labels(_siloConfig, silo0, "0");
        _labels(_siloConfig, silo1, "1");
    }

    function _setLabels(
        ISiloConfig _controllerSiloConfig,
        ISiloConfig _responderSiloConfig
    ) internal virtual {
        vm.label(address(ArbitrumLib.SILO_DEPLOYER), "SILO_DEPLOYER");
        vm.label(
            address(ArbitrumLib.CHAINLINK_ETH_USD_AGREGATOR),
            "CHAINLINK_ETH_USD_AGREGATOR"
        );
        vm.label(address(ArbitrumLib.WETH), "WETH");
        vm.label(address(ArbitrumLib.USDC), "USDC");

        vm.label(address(_controllerSiloConfig), "controllerSiloConfig");
        vm.label(address(_responderSiloConfig), "responderSiloConfig");

        // Label controller silos
        (
            address controllerSilo0,
            address controllerSilo1
        ) = _controllerSiloConfig.getSilos();
        _labels(_controllerSiloConfig, controllerSilo0, "Controller0");
        _labels(_controllerSiloConfig, controllerSilo1, "Controller1");

        // Label responder silos
        (address responderSilo0, address responderSilo1) = _responderSiloConfig
            .getSilos();
        _labels(_responderSiloConfig, responderSilo0, "Responder0");
        _labels(_responderSiloConfig, responderSilo1, "Responder1");
    }

    function _labels(
        ISiloConfig _siloConfig,
        address _silo,
        string memory _i
    ) internal virtual {
        ISiloConfig.ConfigData memory config = _siloConfig.getConfig(_silo);

        // Try to determine if this is a controller or responder silo by checking the hook type
        string memory siloType = "";
        if (_isControllerHook(config.hookReceiver)) {
            siloType = "Controller";
        } else if (_isResponderHook(config.hookReceiver)) {
            siloType = "Responder";
        }

        // Add the silo type to the labels if it was determined
        string memory siloLabel = string.concat(
            "collateralShareToken/silo",
            _i
        );
        if (bytes(siloType).length > 0) {
            siloLabel = string.concat(siloLabel, "/", siloType);
        }
        vm.label(config.silo, siloLabel);

        // Add the hook type to the hook label if it was determined
        string memory hookLabel = string.concat("hookReceiver", _i);
        if (bytes(siloType).length > 0) {
            hookLabel = string.concat(hookLabel, "/", siloType, "Hook");
        }
        vm.label(config.hookReceiver, hookLabel);

        vm.label(
            config.protectedShareToken,
            string.concat("protectedShareToken", _i)
        );
        vm.label(config.debtShareToken, string.concat("debtShareToken", _i));
        vm.label(
            config.interestRateModel,
            string.concat("interestRateModel", _i)
        );
        vm.label(config.maxLtvOracle, string.concat("maxLtvOracle", _i));
        vm.label(config.solvencyOracle, string.concat("solvencyOracle", _i));
        vm.label(
            config.token,
            string.concat(IERC20Metadata(config.token).symbol(), _i)
        );
    }

    // Helper function to check if a hook is a controller hook
    function _isControllerHook(address _hook) internal view returns (bool) {
        try ControllerSiloHook(_hook).controllerSilo() returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    // Helper function to check if a hook is a responder hook
    function _isResponderHook(address _hook) internal view returns (bool) {
        try ResponderSiloHook(_hook).responderSilo() returns (address) {
            return true;
        } catch {
            return false;
        }
    }

    // Add specific labels for controller and responder silos
    function _setControllerResponderLabels(
        address _controllerSilo,
        address _responderSilo,
        address _controllerHook,
        address _responderHook
    ) internal virtual {
        // Label controller silo and its hook
        vm.label(_controllerSilo, "CONTROLLER_SILO");
        vm.label(_controllerHook, "CONTROLLER_HOOK");

        // Label responder silo and its hook
        vm.label(_responderSilo, "RESPONDER_SILO");
        vm.label(_responderHook, "RESPONDER_HOOK");
    }
}
