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
    ISilo public controllerSilo;
    ISilo public responderSilo;

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

        controllerSilo = ISilo(clonedControllerHook.controllerSilo());

        responderSiloConfig = deployer.deploySilo(
            ArbitrumLib.SILO_DEPLOYER,
            address(new ResponderSiloHook()),
            abi.encode(address(this), ArbitrumLib.WETH, controllerSilo)
        );

        clonedResponderHook = ResponderSiloHook(
            _getHookAddress(responderSiloConfig)
        );

        responderSilo = ISilo(clonedResponderHook.responderSilo());

        clonedControllerHook.registerResponderSilo(
            address(responderSilo),
            address(clonedResponderHook)
        );

        _setLabels(controllerSiloConfig, responderSiloConfig);

        // Add specific controller/responder labels
        _setControllerResponderLabels(
            address(controllerSilo),
            address(responderSilo),
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
        _deposit(controllerSilo, ArbitrumLib.WETH_WHALE, 1e21);

        _userHasShares(controllerSilo, ArbitrumLib.WETH_WHALE, 1e21);
        _siloHasAssets(controllerSilo, 1e21);
        _siloHasSomeTotalSupply(controllerSilo);

        _userHasShares(responderSilo, address(controllerSilo), 1e21);

        _siloHasSomeTotalSupply(responderSilo);
        _siloHasNoAssets(responderSilo);
    }

    function _withdraw(ISilo _silo, address _user, uint256 _amount) internal {
        vm.startPrank(_user);
        _silo.withdraw(_amount, _user, _user);
        vm.stopPrank();
    }

    function _withdrawFromControllerSilo() internal {
        _withdraw(controllerSilo, ArbitrumLib.WETH_WHALE, 1e21);
    }

    function _withdrawFromResponderSilo() internal {
        _withdraw(responderSilo, ArbitrumLib.WETH_WHALE, 1e21);
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

    function _siloHasNoAssets(ISilo _silo) internal {
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

    function _siloHasNoSharesFromOtherSilo(
        ISilo _silo,
        ISilo _otherSilo
    ) internal {
        assertEq(
            _otherSilo.balanceOf(address(_silo)),
            0,
            "silo should not have collateral from other silo"
        );
    }

    function _hasTokenBalance(
        address _token,
        address _user,
        uint256 _amount
    ) internal {
        assertEq(
            IERC20(_token).balanceOf(_user),
            _amount,
            "user should have token balance"
        );
    }

    function test_WithdrawFromControllerSilo() public {
        uint256 initialUserWETHBalance = IERC20(ArbitrumLib.WETH).balanceOf(
            ArbitrumLib.WETH_WHALE
        );

        _depositToControllerSilo();
        _withdrawFromControllerSilo();
        _siloHasNoAssets(controllerSilo);
        _userHasShares(controllerSilo, ArbitrumLib.WETH_WHALE, 0);

        assertEq(
            IERC20(ArbitrumLib.WETH).balanceOf(ArbitrumLib.WETH_WHALE),
            initialUserWETHBalance,
            "user should have token balance"
        );

        _siloHasNoSharesFromOtherSilo(controllerSilo, responderSilo);
    }

    function _depositToResponderSilo() internal {
        _deposit(responderSilo, ArbitrumLib.WETH_WHALE, 1e21);
    }

    function test_WithdrawFromResponderSilo() public {
        uint256 initialUserWETHBalance = IERC20(ArbitrumLib.WETH).balanceOf(
            ArbitrumLib.WETH_WHALE
        );

        _depositToControllerSilo();
        _siloHasSomeTotalSupply(responderSilo);
        _userHasShares(responderSilo, ArbitrumLib.WETH_WHALE, 0);
        _siloHasAssets(responderSilo, 0);

        _depositToResponderSilo();
        _userHasShares(responderSilo, ArbitrumLib.WETH_WHALE, 1e21);
        _siloHasAssets(responderSilo, 1e21);
        _siloHasSomeTotalSupply(responderSilo);

        _withdrawFromResponderSilo();
        _siloHasNoAssets(responderSilo);
        _userHasShares(responderSilo, ArbitrumLib.WETH_WHALE, 0);

        _hasTokenBalance(
            ArbitrumLib.WETH,
            ArbitrumLib.WETH_WHALE,
            initialUserWETHBalance - 1e21
        );
    }

    function _borrow(ISilo _silo, address _user, uint256 _amount) internal {
        vm.startPrank(_user);
        _silo.borrow(_amount, _user, _user);
        vm.stopPrank();
    }

    function test_Borrow() public {
        _depositToControllerSilo();
        _depositToResponderSilo();

        _borrow(controllerSilo, ArbitrumLib.WETH_WHALE, 1e21);
    }
}
