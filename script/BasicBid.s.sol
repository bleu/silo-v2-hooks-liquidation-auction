// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.28;

import "forge-std/Script.sol";
import {IERC20} from "openzeppelin5/token/ERC20/IERC20.sol";

interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IAuctionHook {
    function placeBid(address borrower, uint256 amount) external;
}

contract BasicBid is Script {
    address constant WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    function run() external {
        address auctionHookAddress = vm.envAddress("AUCTION_HOOK_ADDRESS");
        address borrowerAddress = vm.envAddress("BORROWER_ADDRESS");
        address bidderAddress = vm.envAddress("BIDDER_A");

        uint256 bidAmount = vm.envOr("BID_AMOUNT", uint256(1 ether));

        console.log("Auction Hook:", auctionHookAddress);
        console.log("Borrower:", borrowerAddress);
        console.log("Bidder:", bidderAddress);
        console.log("Bid Amount:", bidAmount);

        // Use startBroadcast without a private key
        vm.startBroadcast();

        // Transfer ETH to the bidder first (if needed)
        if (bidderAddress != address(0) && bidderAddress != msg.sender) {
            payable(bidderAddress).transfer(bidAmount * 2);
            // Use prank to act as the bidder
            vm.startPrank(bidderAddress);
        }

        IWETH weth = IWETH(WETH);
        IAuctionHook hook = IAuctionHook(auctionHookAddress);

        // Step 1: Deposit ETH to get WETH
        console.log("Depositing ETH to get WETH...");
        weth.deposit{value: bidAmount + 0.1 ether}(); // Add a little extra

        // Step 2: Approve WETH spending
        console.log("Approving WETH spending...");
        weth.approve(auctionHookAddress, bidAmount);

        // Step 3: Place the bid
        console.log("Placing bid...");
        hook.placeBid(borrowerAddress, bidAmount);

        console.log("Bid successfully placed!");

        // Stop pranking if we started
        if (bidderAddress != address(0) && bidderAddress != msg.sender) {
            vm.stopPrank();
        }

        vm.stopBroadcast();
    }
}
