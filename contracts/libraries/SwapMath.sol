// SPDX-License-Identifier: agpl-3.0
pragma solidity >=0.8.0;

import {MathConstants} from './MathConstants.sol';
import {FullMath} from './FullMath.sol';
import {SafeCast} from './SafeCast.sol';
// import 'hardhat/console.sol';

/// @title Contains helper functions for swaps
library SwapMath {
  using SafeCast for uint256;
  using SafeCast for int256;

  function computeSwapStep(
    uint256 liquidity,
    uint160 currentSqrtP,
    uint160 targetSqrtP,
    uint16 feeInBps,
    int256 amountRemaining,
    bool isExactInput,
    bool isToken0
  )
    internal
    pure
    returns (
      int256 delta,
      int256 actualDelta,
      uint256 fee,
      uint160 nextSqrtP
    )
  {
    delta = calcDeltaNext(liquidity, currentSqrtP, targetSqrtP, feeInBps, isExactInput, isToken0);

    if (isExactInput) {
      if (delta >= amountRemaining) {
        delta = amountRemaining;
      } else {
        nextSqrtP = targetSqrtP;
      }
    } else {
      if (delta <= amountRemaining) {
        delta = amountRemaining;
      } else {
        nextSqrtP = targetSqrtP;
      }
    }
    uint256 absDelta = delta >= 0 ? uint256(delta) : delta.revToUint256();
    if (nextSqrtP == 0) {
      fee = calcFinalSwapFeeAmount(absDelta, liquidity, currentSqrtP, feeInBps, isExactInput, isToken0);
      nextSqrtP = calcFinalPrice(absDelta, liquidity, fee, currentSqrtP, isExactInput, isToken0);
    } else {
      fee = calcStepSwapFeeAmount(absDelta, liquidity, currentSqrtP, nextSqrtP, feeInBps, isExactInput, isToken0);
    }
    actualDelta = calcActualDelta(liquidity, currentSqrtP, nextSqrtP, fee, isExactInput, isToken0);
  }

  // calculates the delta qty amount needed to reach sqrtPn (price of next tick)
  // from sqrtPc (price of current tick)
  // each of the 4 possible scenarios (isExactInput | isToken0)
  // have vastly different formulas which are elaborated in each branch
  function calcDeltaNext(
    uint256 liquidity,
    uint160 sqrtPc,
    uint160 sqrtPn,
    uint16 feeInBps,
    bool isExactInput,
    bool isToken0
  ) internal pure returns (int256 deltaNext) {
    uint256 absPriceDiff = (sqrtPc >= sqrtPn) ? (sqrtPc - sqrtPn) : (sqrtPn - sqrtPc);
    uint256 numerator;
    uint256 denominator;
    if (isExactInput) {
      // we round down so that we avoid taking giving away too much for the specified input
      // ie. require less input qty to move ticks
      if (isToken0) {
        // numerator = 2 * liquidity * absPriceDiff
        // overflow should not happen because the absPriceDiff is capped to ~5%
        // denominator = sqrtPc * (2 * sqrtPn - sqrtPc * feeInBps / BPS)
        numerator = 2 * liquidity * absPriceDiff;
        denominator = 2 * sqrtPn - (sqrtPc * feeInBps) / MathConstants.BPS;
        denominator = FullMath.mulDivCeiling(sqrtPc, denominator, MathConstants.TWO_POW_96);
        deltaNext = (numerator / denominator).toInt256();
      } else {
        // numerator = 2 * liquidity * absPriceDiff
        // overflow should not happen because the absPriceDiff is capped to ~5%
        // denominator = 2 * sqrtPc - sqrtPn * feeInBps / BPS
        numerator = FullMath.mulDivFloor(2 * liquidity, absPriceDiff, MathConstants.TWO_POW_96);
        denominator = 2 * sqrtPc - (sqrtPn * feeInBps) / MathConstants.BPS;
        deltaNext = FullMath.mulDivFloor(numerator, sqrtPc, denominator).toInt256();
      }
    } else {
      // we will perform negation as the last step
      // common terms in both cases are (liquidity)(absPriceDiff) and fee * (sqrtPc + sqrtPn)
      // hence can calculate these terms first
      // we round up to take as much as possible from specified output
      numerator = liquidity * absPriceDiff;
      uint256 feeMulSumPrices = (feeInBps * (sqrtPc + sqrtPn)) / MathConstants.BPS;
      if (isToken0) {
        // numerator: (liquidity)(absPriceDiff)(2 * sqrtPc - fee * (sqrtPc + sqrtPn))
        // denominator: (sqrtPc * sqrtPn) * (2 * sqrtPc - fee * sqrtPn)
        numerator = FullMath.mulDivCeiling(
          numerator,
          2 * sqrtPc - feeMulSumPrices,
          MathConstants.TWO_POW_96
        );
        denominator = FullMath.mulDivFloor(sqrtPc, sqrtPn, MathConstants.TWO_POW_96);
        denominator = denominator * (2 * sqrtPc - (feeInBps * sqrtPn) / MathConstants.BPS);
        deltaNext = FullMath
        .mulDivCeiling(numerator, MathConstants.TWO_POW_96, denominator)
        .toInt256();
      } else {
        // numerator: (liquidity)(absPriceDiff)(2 * sqrtPn - fee * (sqrtPn + sqrtPc))
        // denominator: (2 * sqrtPn - fee * sqrtPc)
        numerator = FullMath.mulDivCeiling(
          numerator,
          2 * sqrtPn - feeMulSumPrices,
          MathConstants.TWO_POW_96
        );
        denominator = 2 * sqrtPn - (feeInBps * sqrtPc) / MathConstants.BPS;
        deltaNext = (numerator / denominator).toInt256();
      }
      deltaNext = -deltaNext;
    }
  }

  function calcFinalSwapFeeAmount(
    uint256 absDelta,
    uint256 liquidity,
    uint160 sqrtPc,
    uint16 feeInBps,
    bool isExactInput,
    bool isToken0
  ) internal pure returns (uint256 lc) {
    if (isExactInput) {
      if (isToken0) {
        // lc = fee * absDelta * sqrtPc / 2
        lc = FullMath.mulDivFloor(
          sqrtPc,
          absDelta * feeInBps,
          2 * MathConstants.TWO_POW_96 * MathConstants.BPS
        );
      } else {
        // lc = fee * absDelta * / (sqrtPc * 2)
        lc = FullMath.mulDivFloor(
          MathConstants.TWO_POW_96,
          absDelta * feeInBps,
          2 * sqrtPc * MathConstants.BPS
        );
      }
    } else {
      // obtain the smaller root of the quadratic equation
      // ax^2 - bx + c = 0 such that b > 0, and x denotes lc
      uint256 a;
      uint256 b;
      uint256 c = liquidity * feeInBps * absDelta;
      if (isToken0) {
        // solving fee * lc^2 - 2 * [(1 - fee) * liquidity - absDelta * sqrtPc] * lc + liquidity * fee * absDelta * sqrtPc = 0
        // multiply both sides by BPS to avoid the 'a' variable becoming 0
        // a = feeInBps
        // b = 2 * [(BPS - feeInBps) * liquidity - BPS * absDelta * sqrtPc]
        // c = liquidity * feeInBps * absDelta * sqrtPc
        a = feeInBps;
        b = FullMath.mulDivFloor(MathConstants.BPS * absDelta, sqrtPc, MathConstants.TWO_POW_96);
        b = (MathConstants.BPS - feeInBps) * liquidity - b;
        c = FullMath.mulDivFloor(c, sqrtPc, MathConstants.TWO_POW_96);
      } else {
        // solving fee * sqrtPc * lc^2 - 2 * [liquidity * sqrtPc * (1 - fee) + absDelta] * lc) + liquidity * fee * absDelta = 0
        // multiply both sides by BPS
        // a = feeInBps * sqrtPc
        // b = 2 * [liquidity * sqrtPc * (BPS - feeInBps) + absDelta]
        // c = liquidity * feeInBps * absDelta
        a = FullMath.mulDivFloor(feeInBps, sqrtPc, MathConstants.TWO_POW_96);
        b = FullMath.mulDivFloor(liquidity, sqrtPc, MathConstants.TWO_POW_96);
        b = 2 * (b * (MathConstants.BPS - feeInBps) + absDelta);
      }
      lc = getSmallerRootOfQuadEqn(a, b, c);
    }
  }

  // since our equation is ax^2 - bx + c = 0, b > 0,
  // qudratic formula to obtain the smaller root is b - sqrt(b^2 - 4ac) / 2a
  function getSmallerRootOfQuadEqn(
    uint256 a,
    uint256 b,
    uint256 c
  ) internal pure returns (uint256 smallerRoot) {
    smallerRoot = (b - sqrt(b * b - 4 * a * c)) / 2 * a; 
  }

  function calcStepSwapFeeAmount(
    uint256 absDelta,
    uint256 liquidity,
    uint160 sqrtPc,
    uint160 sqrtPn,
    uint16 feeInBps,
    bool isExactInput,
    bool isToken0
  ) internal pure returns (uint256 lc) {
    if (isExactInput) {
      if (isToken0) {
        // lc = fee * absDelta * sqrtPc / 2
        lc = FullMath.mulDivFloor(
          sqrtPc,
          absDelta * feeInBps,
          2 * MathConstants.TWO_POW_96 * MathConstants.BPS
        );
      } else {
        // lc = fee * absDelta * / (sqrtPc * 2)
        lc = FullMath.mulDivFloor(
          MathConstants.TWO_POW_96,
          absDelta * feeInBps,
          2 * sqrtPc * MathConstants.BPS
        );
      }
    } else {
      if (isToken0) {
        // lc = sqrtPn * (liquidity / sqrtPc + (-absDelta)) - liquidity
        // needs to be maximum
        lc = FullMath.mulDivCeiling(liquidity, MathConstants.TWO_POW_96, sqrtPc) - absDelta;
        lc = FullMath.mulDivCeiling(sqrtPn, lc, MathConstants.TWO_POW_96) - liquidity;
      } else {
        // lc = (liquidity * sqrtPc + (-absDelta)) / sqrtPn - liquidity
        // needs to be minimum
        lc = FullMath.mulDivFloor(liquidity, sqrtPc, MathConstants.TWO_POW_96) - absDelta;
        lc = FullMath.mulDivFloor(lc, MathConstants.TWO_POW_96, sqrtPn) - liquidity;
      }
    }
  }

  // will round down sqrtPn
  function calcFinalPrice(
    uint256 absDelta,
    uint256 liquidity,
    uint256 lc,
    uint160 sqrtPc,
    bool isExactInput,
    bool isToken0
  ) internal pure returns (uint160 sqrtPn) {
    uint256 numerator;
    if (isToken0) {
      numerator = FullMath.mulDivFloor(liquidity + lc, sqrtPc, MathConstants.TWO_POW_96);
      uint256 denominator = FullMath.mulDivCeiling(absDelta, sqrtPc, MathConstants.TWO_POW_96);
      sqrtPn = (
        FullMath.mulDivFloor(
          numerator,
          MathConstants.TWO_POW_96,
          isExactInput ? liquidity + denominator : liquidity - denominator
        )
      )
      .toUint160();
    } else {
      numerator = FullMath.mulDivFloor(liquidity, sqrtPc, MathConstants.TWO_POW_96);
      numerator = isExactInput ? numerator + absDelta : numerator - absDelta;
      sqrtPn = FullMath
      .mulDivFloor(numerator, MathConstants.TWO_POW_96, liquidity + lc)
      .toUint160();
    }
  }

  // calculates actual output | input tokens in exchange for
  // user specified input | output
  // round down when calculating actual output (isExactInput) so we avoid sending too much
  // round up when calculating actual input (!isExactInput) so we get desired output amount
  function calcActualDelta(
    uint256 liquidity,
    uint160 sqrtPc,
    uint160 sqrtPn,
    uint256 lc,
    bool isExactInput,
    bool isToken0
  ) internal pure returns (int256 actualDelta) {
    if (isToken0) {
      // require difference in sqrtPc and sqrtPn > 0
      // so that we can properly do the multiplication of (liquidity)|sqrtPc - sqrtPn|
      // hence, if user specified
      // exact input: actualDelta = lc(sqrtPn) - [(liquidity)(sqrtPc - sqrtPn)]
      // exact output: actualDelta = lc(sqrtPn) + (liquidity)(sqrtPn - sqrtPc)

      if (isExactInput) {
        // round down actual output so we avoid sending too much
        // actualDelta = lc(sqrtPn) - [(liquidity)(sqrtPc - sqrtPn)]
        actualDelta =
          FullMath.mulDivFloor(lc, sqrtPn, MathConstants.TWO_POW_96).toInt256() +
          FullMath
          .mulDivCeiling(liquidity, sqrtPc - sqrtPn, MathConstants.TWO_POW_96)
          .revToInt256();
      } else {
        // round up actual input so we get desired output amount
        // actualDelta = lc(sqrtPn) + (liquidity)(sqrtPn - sqrtPc)
        actualDelta =
          FullMath.mulDivCeiling(lc, sqrtPn, MathConstants.TWO_POW_96).toInt256() +
          FullMath.mulDivCeiling(liquidity, sqrtPn - sqrtPc, MathConstants.TWO_POW_96).toInt256();
      }
    } else {
      // actualDelta = (liquidity + lc)/sqrtPn - (liquidity)/sqrtPc
      if (isExactInput) {
        // round down actual output so we avoid sending too much
        actualDelta =
          FullMath.mulDivFloor(liquidity + lc, MathConstants.TWO_POW_96, sqrtPn).toInt256() +
          FullMath.mulDivCeiling(liquidity, MathConstants.TWO_POW_96, sqrtPc).revToInt256();
      } else {
        // round up actual input so we get desired output amount
        actualDelta =
          FullMath.mulDivCeiling(liquidity + lc, MathConstants.TWO_POW_96, sqrtPn).toInt256() +
          FullMath.mulDivFloor(liquidity, MathConstants.TWO_POW_96, sqrtPc).revToInt256();
      }
    }
  }

  // babylonian method (https://en.wikipedia.org/wiki/Methods_of_computing_square_roots#Babylonian_method)
  function sqrt(uint256 y) internal pure returns (uint256 z) {
    if (y > 3) {
      z = y;
      uint256 x = y / 2 + 1;
      while (x < z) {
        z = x;
        x = (y / x + x) / 2;
      }
    } else if (y != 0) {
      z = 1;
    }
  }
}
