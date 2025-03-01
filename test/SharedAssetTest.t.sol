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

        // Register the responder hook with the controller hook
        clonedControllerHook.registerResponderHook(
            address(clonedResponderHook)
        );

        _setLabels(controllerSiloConfig, responderSiloConfig);

        // Add specific controller/responder labels
        _setControllerResponderLabels(
            address(siloController),
            address(siloResponder),
            address(clonedControllerHook),
            address(clonedResponderHook)
        );
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

    // create a function to set up the test scenario where the controller Silo virtually distributes
    // the collateral token to the responder silos but does not transfer the assets to the responder silos
    function _depositToControllerSilo() internal {
        _deposit(siloController, ArbitrumLib.WETH_WHALE, 1e21);

        _userHasShares(siloController, ArbitrumLib.WETH_WHALE, 1e21);
        _siloHasAssets(siloController, 1e21);
        _siloHasSomeTotalSupply(siloController);

        _userHasShares(siloResponder, address(siloController), 1e21);

        _siloHasSomeTotalSupply(siloResponder);
        _siloDoesNotHaveAssets(siloResponder, 1e21);
    }

    function _withdrawFromControllerSilo() internal {
        _withdraw(siloController, ArbitrumLib.WETH_WHALE, 1e21);
    }

    function _userHasShares(
        ISilo _silo,
        address _user,
        uint256 _amount
    ) internal {
        assertEq(
            _silo.balanceOf(_user),
            _silo.convertToShares(_amount),
            "user should have shares from controller silo"
        );
    }

    function _siloHasAssets(ISilo _silo, uint256 _amount) internal {
        assertEq(
            IERC20(_silo.asset()).balanceOf(address(_silo)),
            _amount,
            "silo should have assets"
        );
    }

    function _siloDoesNotHaveAssets(ISilo _silo, uint256 _amount) internal {
        assertEq(
            IERC20(_silo.asset()).balanceOf(address(_silo)),
            0,
            "silo should not have assets"
        );
    }

    function _siloHasSomeTotalSupply(ISilo _silo) internal {
        assertGt(_silo.totalSupply(), 0, "silo should have a total supply");
    }

    function test_DepositToControllerSilo() public {
        _depositToControllerSilo();
    }
}
