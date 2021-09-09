// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity 0.8.4;
pragma abicoder v2;

import {IERC721} from '@openzeppelin/contracts/token/ERC721/IERC721.sol';
import {INonfungiblePositionManager, IERC721Metadata, IRouterTokenHelper} from '../interfaces/periphery/INonfungiblePositionManager.sol';
import {IERC20, IProAMMPool, IProAMMFactory} from '../interfaces/IProAMMPool.sol';
import {INonfungibleTokenPositionDescriptor} from '../interfaces/periphery/INonfungibleTokenPositionDescriptor.sol';
import {FullMath} from '../libraries/FullMath.sol';
import {MathConstants} from '../libraries/MathConstants.sol';
import {LiquidityHelper, ImmutableRouterStorage, RouterTokenHelper} from './base/LiquidityHelper.sol';
import {Multicall} from './base/Multicall.sol';
import {DeadlineValidation} from './base/DeadlineValidation.sol';
import {ERC721Permit, ERC721} from './base/ERC721Permit.sol';


contract NonfungiblePositionManager is
  INonfungiblePositionManager,
  Multicall,
  ERC721Permit,
  LiquidityHelper
{
  struct Position {
    // the nonce for permits
    uint96 nonce;
    // the address that is approved for spending this token
    address operator;
    // the ID of the pool with which this token is connected
    uint80 poolId;
    // the tick range of the position
    int24 tickLower;
    int24 tickUpper;
    // the liquidity of the position
    uint128 liquidity;
    // the current rToken that the position owed
    uint256 rTokenOwed;
    // fee growth per unit of liquidity as of the last update to liquidity
    uint256 feeGrowthInsideLast;
  }

  struct PoolInfo {
    address token0;
    uint16 fee;
    address token1;
    address rToken;
  }

  address private immutable _tokenDescriptor;

  // pool address => pool id
  mapping (address => uint80) private _addressToPoolId;
  // pool id => pool info
  mapping (uint80 => PoolInfo) private _poolInfoById;
  mapping (address => bool) public isRToken;
  mapping (uint80 => mapping (int24 => mapping (int24 => uint256))) public totalLiquidity;

  uint80 private _nextPoolId = 1;
  uint256 private _nextTokenId = 1;

  // tokenId => Position
  mapping (uint256 => Position) private _positions;

  constructor(address _factory, address _WETH, address _descriptor)
    ERC721Permit('ProAMM NFT Positions V1', 'PRO-AMM-POS-V1', '1')
    ImmutableRouterStorage(_factory, _WETH)
  {
    _tokenDescriptor = _descriptor;
  }

  function createAndUnlockPoolIfNecessary(
    address token0,
    address token1,
    uint16 fee,
    uint160 sqrtPriceX96
  ) external payable override returns (address pool) {
    require(token0 < token1);
    pool = IProAMMFactory(factory).getPool(token0, token1, fee);

    if (pool == address(0)) {
      pool = IProAMMFactory(factory).createPool(token0, token1, fee);
    }

    (uint160 poolSqrtPriceX96, , , ) = IProAMMPool(pool).getPoolState();
    if (poolSqrtPriceX96 == 0) {
      IProAMMPool(pool).unlockPool(sqrtPriceX96, _callbackData(token0, token1, fee));
    }
  }

  function mint(MintParams calldata params)
    external
    payable
    override
    onlyNotExpired(params.deadline)
    returns (
      uint256 tokenId,
      uint128 liquidity,
      uint256 amount0,
      uint256 amount1,
      uint256 feesClaimable
    )
  {
    IProAMMPool pool;
  
    (liquidity, amount0, amount1, feesClaimable, pool) = addLiquidity(AddLiquidityParams({
      token0: params.token0, token1: params.token1, fee: params.fee, recipient: address(this),
      tickLower: params.tickLower, tickUpper: params.tickUpper,
      amount0Desired: params.amount0Desired, amount1Desired: params.amount1Desired,
      amount0Min: params.amount0Min, amount1Min: params.amount1Min
    }));

    tokenId = _nextTokenId++;
    _mint(params.recipient, tokenId);

    uint80 poolId = _storePoolInfo(
      address(pool),
      PoolInfo({ token0: params.token0, fee: params.fee, token1: params.token1, rToken: address(pool.reinvestmentToken()) })
    );

    uint256 feeGrowthInsideLast = _getFeeGrowInside(pool, params.tickLower, params.tickUpper);

    _positions[tokenId] = Position({
      nonce: 0,
      operator: address(0),
      poolId: poolId,
      tickLower: params.tickLower,
      tickUpper: params.tickUpper,
      liquidity: liquidity,
      rTokenOwed: 0,
      feeGrowthInsideLast: feeGrowthInsideLast
    });
  }

  function addLiquidity(IncreaseLiquidityParams calldata params)
    external
    payable
    override
    onlyNotExpired(params.deadline)
    returns (
      uint128 liquidity,
      uint256 amount0,
      uint256 amount1,
      uint256 feesClaimable
    )
  {
    Position storage pos = _positions[params.tokenId];
    PoolInfo memory poolInfo = _poolInfoById[pos.poolId];
    IProAMMPool pool;

    (liquidity, amount0, amount1, feesClaimable, pool) = addLiquidity(AddLiquidityParams({
      token0: poolInfo.token0, token1: poolInfo.token1, fee: poolInfo.fee, recipient: address(this),
      tickLower: pos.tickLower, tickUpper: pos.tickUpper,
      amount0Desired: params.amount0Desired, amount1Desired: params.amount1Desired,
      amount0Min: params.amount0Min, amount1Min: params.amount1Min
    }));

    uint256 feeGrowthInsideLast = _getFeeGrowInside(pool, pos.tickLower, pos.tickUpper);

    if (feeGrowthInsideLast > pos.feeGrowthInsideLast) {
      pos.rTokenOwed += FullMath.mulDivFloor(
        pos.liquidity,
        feeGrowthInsideLast - pos.feeGrowthInsideLast,
        MathConstants.TWO_POW_96
      );
    }

    pos.liquidity += liquidity;
    pos.feeGrowthInsideLast = feeGrowthInsideLast;
  }

  function removeLiquidity(RemoveLiquidityParams calldata params)
    external
    override
    isAuthorizedForToken(params.tokenId)
    onlyNotExpired(params.deadline)
    returns (
      uint256 amount0,
      uint256 amount1,
      uint256 feesClaimable
    )
  {
    Position storage pos = _positions[params.tokenId];
    require(pos.liquidity >= params.liquidity, 'Insufficient liquidity');

    PoolInfo memory poolInfo = _poolInfoById[pos.poolId];
    IProAMMPool pool = _getPool(poolInfo.token0, poolInfo.token1, poolInfo.fee);

    (amount0, amount1, feesClaimable) = pool.burn(pos.tickLower, pos.tickUpper, params.liquidity);
    require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'Low return amounts');

    uint256 feeGrowthInsideLast = _getFeeGrowInside(pool, pos.tickLower, pos.tickUpper);

    if (feeGrowthInsideLast > pos.feeGrowthInsideLast) {
      pos.rTokenOwed += FullMath.mulDivFloor(
        pos.liquidity,
        feeGrowthInsideLast - pos.feeGrowthInsideLast,
        MathConstants.TWO_POW_96
      );
    }

    pos.liquidity -= params.liquidity;
    pos.feeGrowthInsideLast = feeGrowthInsideLast;
  }

  function burnRTokens(BurnRTokenParams calldata params)
    external
    override
    isAuthorizedForToken(params.tokenId)
    onlyNotExpired(params.deadline)
    returns (
      uint256 rTokenQty,
      uint256 amount0,
      uint256 amount1
    )
  {
    Position storage pos = _positions[params.tokenId];
    PoolInfo memory poolInfo = _poolInfoById[pos.poolId];
    IProAMMPool pool = _getPool(poolInfo.token0, poolInfo.token1, poolInfo.fee);

    rTokenQty = pos.rTokenOwed;
    if (rTokenQty <= 1) return (0, 0, 0);

    // keep 1 twei to save gas
    pos.rTokenOwed = 1;
    rTokenQty -= 1;
    (amount0, amount1) = pool.burnRTokens(rTokenQty);
    require(amount0 >= params.amount0Min && amount1 >= params.amount1Min, 'Low return amounts');
  }

  /**
   * @dev Burn the token by its owner
   * @notice All liquidity should be removed before burning
   */
  function burn(uint256 tokenId) external payable override isAuthorizedForToken(tokenId) {
    require(_positions[tokenId].liquidity == 0, 'Should remove liquidity first');
    require(_positions[tokenId].rTokenOwed == 0, 'Should burn rToken first');
    delete _positions[tokenId];
    _burn(tokenId);
  }

  /**
   * @dev Override this function to not allow transferring rTokens
   * @notice it also means this PositionManager can not work with LP of a rToken and another token
   */
  function transferAllTokens(
    address token,
    uint256 minAmount,
    address recipient
  ) public payable override(IRouterTokenHelper, RouterTokenHelper) {
    require(!isRToken[token], 'Can not transfer rToken');
    super.transferAllTokens(token, minAmount, recipient);
  }

  function _storePoolInfo(address pool, PoolInfo memory info) private returns (uint80 poolId) {
    poolId = _addressToPoolId[pool];
    if (poolId == 0) {
      _addressToPoolId[pool] = (poolId = _nextPoolId++);
      _poolInfoById[poolId] = info;
      isRToken[info.rToken] = true;
    }
  }

  function _getFeeGrowInside(IProAMMPool pool, int24 tickLower, int24 tickUpper)
    internal view
    returns (uint256 feeGrowthInsideLast)
  {
    bytes32 positonKey = _positionKey(tickLower, tickUpper);
    (, feeGrowthInsideLast) = pool.positions(positonKey);
  }

  function _positionKey(int24 tickLower, int24 tickUpper) internal view returns (bytes32) {
    return keccak256(abi.encodePacked(address(this), tickLower, tickUpper));
  }

  modifier isAuthorizedForToken(uint256 tokenId) {
    require(_isApprovedOrOwner(msg.sender, tokenId), 'Not approved');
    _;
  }

  function tokenURI(uint256 tokenId) public view override(ERC721, IERC721Metadata) returns (string memory) {
    require(_exists(tokenId));
    return INonfungibleTokenPositionDescriptor(_tokenDescriptor).tokenURI(this, tokenId);
  }

  function getApproved(uint256 tokenId) public view override(ERC721, IERC721) returns (address) {
    require(_exists(tokenId), 'ERC721: approved query for nonexistent token');
    return _positions[tokenId].operator;
  }

  /// @dev Overrides _approve to use the operator in the position, which is packed with the position permit nonce
  function _approve(address to, uint256 tokenId) internal override(ERC721) {
    _positions[tokenId].operator = to;
    emit Approval(ownerOf(tokenId), to, tokenId);
  }

  function _getAndIncrementNonce(uint256 tokenId) internal override returns (uint256) {
    return uint256(_positions[tokenId].nonce++);
  }

  /**
   * @dev Return the pool for the given token pair and fee. The pool contract may or may not exist.
   *  Use determine function to save gas, instead of reading from factory
   */
  function _getPool(address tokenA, address tokenB, uint16 fee) private view returns (IProAMMPool) {
    return IProAMMPool(IProAMMFactory(factory).getPool(tokenA, tokenB, fee));
  }
}
