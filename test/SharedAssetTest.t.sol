// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import {IHookReceiver} from "silo-contracts-v2/silo-core/contracts/interfaces/IHookReceiver.sol";
import {IERC20} from "openzeppelin5/token/ERC20/IERC20.sol";

import {ISiloConfig} from "silo-core-v2/interfaces/ISiloConfig.sol";
import {ISilo} from "silo-core-v2/interfaces/ISilo.sol";
import {IShareToken, IERC20Metadata} from "silo-core-v2/interfaces/IShareToken.sol";

import {Hook} from "silo-contracts-v2/silo-core/contracts/lib/Hook.sol";

import {SiloDeployer} from "silo-core-v2/SiloDeployer.sol";

import {ControllerSiloHook} from "../contracts/ControllerSiloHook.sol";
import {ResponderSiloHook} from "../contracts/ResponderSiloHook.sol";
import {Labels} from "./common/Labels.sol";
import {DeploySilo} from "./common/DeploySilo.sol";
import {ArbitrumLib} from "./common/ArbitrumLib.sol";

contract SharedAssetTest is Labels {
    ISiloConfig public controllerSiloConfig;
    ISiloConfig public responderSiloConfig;
    ISilo public siloController;
    ISilo public siloResponder;

    ControllerSiloHook public clonedControllerHook;
    ResponderSiloHook public clonedResponderHook;

    function setUp() public {
        uint256 blockToFork = 302603188;
        vm.createSelectFork(vm.envString("RPC_ARBITRUM"), blockToFork);

        DeploySilo deployer = new DeploySilo();

        controllerSiloConfig = deployer.deploySilo(
            ArbitrumLib.SILO_DEPLOYER,
            address(new ControllerSiloHook()),
            abi.encode(address(this), ArbitrumLib.WETH)
        );

        clonedControllerHook = ControllerSiloHook(
            _getHookAddress(controllerSiloConfig)
        );

        emit log_named_address(
            "controllerSiloConfig",
            address(controllerSiloConfig)
        );

        emit log_named_address(
            "clonedControllerHook",
            address(clonedControllerHook)
        );

        siloController = ISilo(clonedControllerHook.siloController());

        responderSiloConfig = deployer.deploySilo(
            ArbitrumLib.SILO_DEPLOYER,
            address(new ResponderSiloHook()),
            abi.encode(address(this), ArbitrumLib.WETH, siloController)
        );

        clonedResponderHook = ResponderSiloHook(
            _getHookAddress(responderSiloConfig)
        );

        siloResponder = ISilo(clonedResponderHook.siloResponder());

        clonedControllerHook.registerResponderSilo(
            clonedResponderHook.siloResponder()
        );

        _setLabels(controllerSiloConfig);
        _setLabels(responderSiloConfig);
    }

    function _getUSDC(address _user, uint256 _amount) internal {
        vm.prank(ArbitrumLib.USDC_WHALE);
        IERC20(ArbitrumLib.USDC).transfer(_user, _amount);
    }

    function _getWETH(address _user, uint256 _amount) internal {
        vm.prank(ArbitrumLib.WETH_WHALE);
        IERC20(ArbitrumLib.WETH).transfer(_user, _amount);
    }

    function _deposit(ISilo _silo, address _user, uint256 _amount) internal {
        vm.startPrank(_user);
        IERC20(_silo.asset()).approve(address(_silo), _amount);
        _silo.deposit(_amount, _user);
        vm.stopPrank();
    }

    function _getHookAddress(
        ISiloConfig _siloConfig
    ) internal view returns (address hook) {
        (address silo, ) = _siloConfig.getSilos();

        hook = _siloConfig.getConfig(silo).hookReceiver;
    }

    function test_DepositToControllerSilo() public {
        // Perform the deposit
        _deposit(siloController, ArbitrumLib.WETH_WHALE, 1e21);

        assertEq(
            IERC20(ArbitrumLib.WETH).balanceOf(address(siloController)),
            1e21
        );
        // check that user has collateral token from controller silo
        assertEq(
            siloController.balanceOf(ArbitrumLib.WETH_WHALE),
            siloController.convertToShares(1e21),
            "user should have shares from controller silo"
        );

        // check that total supply of responder silo is bigger than 0
        assertGt(
            siloResponder.totalSupply(),
            0,
            "responder silo should have a total supply"
        );

        // check that controller silo has collateral token from responder silos
        assertEq(
            siloResponder.balanceOf(address(siloController)),
            siloResponder.convertToShares(1e21),
            "controller silo should have shares from responder silo"
        );
        // check that responder silos do not have any assets (WETH)
        assertEq(
            IERC20(ArbitrumLib.WETH).balanceOf(address(siloResponder)),
            0,
            "responder silos should not have any assets"
        );
    }
}
