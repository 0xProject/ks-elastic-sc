import {ethers} from 'hardhat';

export const BN = ethers.BigNumber;
export const ZERO_ADDRESS = ethers.constants.AddressZero;
export const PRECISION = ethers.constants.WeiPerEther;
export const ZERO = ethers.constants.Zero;
export const ONE = ethers.constants.One;
export const MINUS_ONE = BN.from(-1);
export const TWO = ethers.constants.Two;
export const TWO_POW_96 = TWO.pow(96);
export const TWO_POW_128 = TWO.pow(128);
export const MAX_INT_128 = TWO.pow(127).sub(ONE);
export const MIN_INT_128 = TWO.pow(127).mul(-1);
export const MAX_UINT_128 = TWO.pow(128).sub(ONE);
export const BPS = BN.from(10000);
export const BPS_PLUS_ONE = BPS.add(ONE);
export const MAX_UINT = ethers.constants.MaxUint256;
export const MAX_INT = ethers.constants.MaxInt256;
export const MIN_INT = ethers.constants.MinInt256;
