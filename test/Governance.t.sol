// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseTest} from "./Base.t.sol";
import {ParamController} from "../src/ParamController.sol";
import {IParamController} from "../src/interfaces/IParamController.sol";

/// @notice The change-control surface: bootstrap locks to the timelock, the guardian can only pause,
///         and parameter validation refuses configurations the pricing formula cannot honour.
contract GovernanceTest is BaseTest {
    function _feeCall(uint16 swapFee) internal pure returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            ParamController.setFeeParams,
            (IParamController.FeeParams({swapFeeBps: swapFee, rfqFeeBps: 2, spreadShareBps: 1000}))
        );
    }

    function test_bootstrapLocksSettersToTheTimelock() public {
        vm.prank(gov);
        params.finishBootstrap();

        // Direct setter calls are refused for everyone, the owner included.
        vm.prank(gov);
        vm.expectRevert(ParamController.NotSelf.selector);
        params.setFeeParams(IParamController.FeeParams({swapFeeBps: 5, rfqFeeBps: 2, spreadShareBps: 1000}));

        // The only path is schedule, wait out the delay, execute.
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        params.schedule(calls, bytes32("salt"), keccak256("rationale: fee retune per Q3 execution data"));

        vm.prank(gov);
        vm.expectRevert(ParamController.OperationNotReady.selector);
        params.execute(calls, bytes32("salt"));

        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        params.execute(calls, bytes32("salt"));
        assertEq(params.feeParams().swapFeeBps, 5);
    }

    function test_scheduledOperationCanBeCancelled() public {
        vm.prank(gov);
        params.finishBootstrap();
        bytes[] memory calls = _feeCall(5);
        vm.prank(gov);
        bytes32 id = params.schedule(calls, bytes32("salt"), bytes32(0));
        vm.prank(gov);
        params.cancel(id);
        vm.warp(block.timestamp + 1 days);
        vm.prank(gov);
        vm.expectRevert(ParamController.OperationNotFound.selector);
        params.execute(calls, bytes32("salt"));
    }

    function test_guardianCanPauseAndNothingElse() public {
        vm.prank(guardian);
        params.setPaused(true);
        assertTrue(params.swapsPaused());

        vm.prank(guardian);
        vm.expectRevert(ParamController.NotOwner.selector);
        params.setFeeParams(IParamController.FeeParams({swapFeeBps: 0, rfqFeeBps: 0, spreadShareBps: 0}));

        vm.prank(outsider);
        vm.expectRevert(ParamController.NotGuardian.selector);
        params.setPaused(true);
    }

    function test_tierValidationRefusesUnpriceableConfigs() public {
        // A base spread plus full skew that cannot fit inside the oracle band is refused outright.
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidBps.selector);
        params.setTierConfig(
            4,
            IParamController.TierConfig({
                baseHalfSpreadBps: 60,
                maxSkewBps: 30,
                inventoryBandBps: 2000,
                oracleBandBps: 75,
                maxClip: 1_000e6,
                enabled: true
            })
        );

        // An enabled tier with a zero inventory band would divide skew by zero at the first fill.
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidBps.selector);
        params.setTierConfig(
            4,
            IParamController.TierConfig({
                baseHalfSpreadBps: 10,
                maxSkewBps: 15,
                inventoryBandBps: 0,
                oracleBandBps: 75,
                maxClip: 1_000e6,
                enabled: true
            })
        );
    }

    function test_regimeValidationKeepsMultipliersHonest() public {
        // Session multipliers may only widen spreads and shrink clips.
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidBps.selector);
        params.setRegimeParams(
            IParamController.RegimeParams({
                extendedSpreadMulBps: 9_000,
                closedSpreadMulBps: 30_000,
                extendedClipMulBps: 7_500,
                closedClipMulBps: 5_000
            })
        );
    }

    function test_marketRequiresEnabledTier() public {
        vm.prank(gov);
        vm.expectRevert(ParamController.InvalidTier.selector);
        params.setMarketConfig(
            address(0xBEEF), IParamController.MarketConfig({tier: 9, dailyVolumeCap: 1e6, tvlCap: 1e6, enabled: true})
        );
    }

    function test_ownershipHandoverIsTwoStep() public {
        address next = makeAddr("next");
        vm.prank(gov);
        params.transferOwnership(next);
        assertEq(params.owner(), gov); // nothing changes until the new owner accepts
        vm.prank(next);
        params.acceptOwnership();
        assertEq(params.owner(), next);
    }
}
