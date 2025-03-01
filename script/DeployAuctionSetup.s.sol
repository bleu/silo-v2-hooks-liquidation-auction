// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin5/token/ERC20/IERC20.sol";
import {ISiloConfig} from "silo-contracts-v2/silo-core/contracts/interfaces/ISiloConfig.sol";
import {LiquidationAuctionHook} from "../contracts/LiquidationAuctionHook.sol";
import {DeploySilo} from "../test/common/DeploySilo.sol";
import {ArbitrumLib} from "../test/common/ArbitrumLib.sol";

/**
 * @title DeployAuctionSetup
 * @notice Deployment script to set up auction environment on local node
 * @dev Replicates the test environment in LiquidationAuctionHookArbitrumTest
 */
contract DeployAuctionSetup is Script {
    // Test addresses - make these accessible for your local interaction
    address public bidderA;
    address public bidderB;
    address public borrower;

    ISiloConfig public siloConfig;
    LiquidationAuctionHook public auctionHook;

    function run() public {
        console.log("Deploying from:", msg.sender);

        // Start broadcasting transactions
        vm.startBroadcast();

        // Deploy the system
        DeploySilo deployer = new DeploySilo();

        // Initialize with (owner, feeReceiver, weth address)
        bytes memory initData = abi.encode(
            msg.sender, // Use the deployer as owner
            msg.sender, // Use the deployer as fee receiver
            ArbitrumLib.WETH
        );

        siloConfig = deployer.deploySilo(
            ArbitrumLib.SILO_DEPLOYER,
            address(new LiquidationAuctionHook()),
            initData
        );

        // Retrieve our hook from the silo config
        (address silo, ) = siloConfig.getSilos();
        auctionHook = LiquidationAuctionHook(
            siloConfig.getConfig(silo).hookReceiver
        );

        console.log("Deployed SiloConfig at:", address(siloConfig));
        console.log(
            "Deployed LiquidationAuctionHook at:",
            address(auctionHook)
        );

        vm.stopBroadcast();
    }
}
