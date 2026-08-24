// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {AnchorVault} from "../src/AnchorVault.sol";
import {SwapRouter} from "../src/SwapRouter.sol";
import {Types} from "../src/libraries/Types.sol";

/// @notice Sessions and halts: spreads widen and clips shrink when the underlying market is closed, and
///         every oracle failure mode halts trading instead of mispricing it.
contract RegimesTest is BaseTest {
    function setUp() public override {
        super.setUp();
        _seed(nvdaVault, NVDA_MID);
    }

    function test_closedSessionWidensSpreadAndShrinksClip() public {
        (uint256 regularOut,) = nvdaVault.quoteSwap(true, 10_000e6);

        nvda.setMarketStatus(5); // Chainlink convention: 5 = closed
        (uint256 closedOut, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);

        assertEq(uint8(b.session), uint8(Types.Session.Closed));
        assertEq(b.halfSpreadBps, 30); // 10 bps base at the x3 closed multiplier
        assertLt(closedOut, regularOut);

        // The clip halves: 26,000 fits the 50,000 regular clip but not the 25,000 closed one.
        vm.expectRevert(abi.encodeWithSelector(AnchorVault.ClipExceeded.selector, 26_000e6, 25_000e6));
        nvdaVault.quoteSwap(true, 26_000e6);
    }

    function test_extendedSessionMultiplier() public {
        nvda.setMarketStatus(2);
        (, Types.Breakdown memory b) = nvdaVault.quoteSwap(true, 10_000e6);
        assertEq(uint8(b.session), uint8(Types.Session.Extended));
        assertEq(b.halfSpreadBps, 15); // 10 bps base at the x1.5 extended multiplier
    }

    function test_staleFeedHaltsTrading() public {
        vm.warp(block.timestamp + 2 hours); // regular-session staleness bound is 1 hour
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // A fresh round clears the halt on its own; no privileged action involved.
        nvdaFeed.set(int256(NVDA_PRICE_8));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_corporateActionPausesAndResumes() public {
        nvda.setOraclePaused(true);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        nvda.setOraclePaused(false);
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_moveCapPausesMarketPendingReview() public {
        _swap(address(usdg), address(nvda), 1_000e6); // writes the first checkpoint

        // A 30% print against a 25% cap: the preview still prices, but the fill's refresh trips the
        // cap and the market pauses pending review instead of filling on the suspect round.
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        vm.prank(trader);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        router.swapExactIn(_params(address(usdg), address(nvda), 1_000e6, 0));

        // Clearing the pause is a governance action with a published rationale.
        vm.prank(gov);
        oracle.resume(address(nvda));
        vm.warp(block.timestamp + 2 hours); // leave the move-cap window, then refresh the feed
        nvdaFeed.set(int256(NVDA_PRICE_8 * 130 / 100));
        assertGt(_swap(address(usdg), address(nvda), 1_000e6), 0);
    }

    function test_sequencerOutageAndGrace() public {
        sequencer.setWithTimestamps(1, block.timestamp, block.timestamp); // down
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        // Back up, but inside the one-hour grace: still halted.
        sequencer.setWithTimestamps(0, block.timestamp, block.timestamp);
        vm.expectRevert(AnchorVault.MarketHalted.selector);
        nvdaVault.quoteSwap(true, 1_000e6);

        vm.warp(block.timestamp + 61 minutes);
        nvdaFeed.set(int256(NVDA_PRICE_8));
        (uint256 out,) = nvdaVault.quoteSwap(true, 1_000e6);
        assertGt(out, 0);
    }

    function test_multiplierReportedNotDoubleApplied() public view {
        // Chainlink equity feeds already include the ERC-8056 multiplier; the router reports it for
        // display and never applies it to the price.
        assertEq(oracle.quote(address(nvda)).multiplier, 1e18);
        assertEq(oracle.quote(address(nvda)).price, NVDA_MID);
    }
}
