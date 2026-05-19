// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity ^0.8.24;

import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { Errors } from "@openzeppelin/contracts/utils/Errors.sol";

import { TokenConfig, TokenType, PoolRoleAccounts } from "@balancer-labs/v3-interfaces/contracts/vault/VaultTypes.sol";
import { IRateProvider } from "@balancer-labs/v3-interfaces/contracts/solidity-utils/helpers/IRateProvider.sol";
import { IVaultMock } from "@balancer-labs/v3-interfaces/contracts/test/IVaultMock.sol";
import { IVault } from "@balancer-labs/v3-interfaces/contracts/vault/IVault.sol";

import { VaultContractsDeployer } from "@balancer-labs/v3-vault/test/foundry/utils/VaultContractsDeployer.sol";
import { ERC20TestToken } from "@balancer-labs/v3-solidity-utils/contracts/test/ERC20TestToken.sol";
import { MinTokenBalanceLib } from "@balancer-labs/v3-vault/contracts/lib/MinTokenBalanceLib.sol";
import { RateProviderMock } from "@balancer-labs/v3-vault/contracts/test/RateProviderMock.sol";
import { BasicAuthorizerMock } from "@balancer-labs/v3-solidity-utils/contracts/test/BasicAuthorizerMock.sol";

import { WeightedPoolContractsDeployer } from "./utils/WeightedPoolContractsDeployer.sol";
import { WeightedPool8020Factory } from "../../contracts/WeightedPool8020Factory.sol";
import { WeightedPool } from "../../contracts/WeightedPool.sol";

contract WeightedPool8020FactoryTest is WeightedPoolContractsDeployer, VaultContractsDeployer {
    uint256 internal DEFAULT_SWAP_FEE = 1e16; // 1%

    IVaultMock vault;
    WeightedPool8020Factory factory;
    RateProviderMock rateProvider;
    ERC20TestToken tokenA;
    ERC20TestToken tokenB;
    ERC20TestToken tokenC;

    address alice = vm.addr(1);
    address governance = vm.addr(2);

    event TokenConfigAllowlisted(TokenConfig tokenConfig);

    function setUp() public {
        vault = deployVaultMock();
        factory = deployWeightedPool8020Factory(IVault(address(vault)), 365 days, "Factory v1", "8020Pool v1");

        tokenA = new ERC20TestToken("Token A", "TKNA", 18);
        tokenB = new ERC20TestToken("Token B", "TKNB", 6);
        tokenC = new ERC20TestToken("Token C", "TKNC", 18);

        _grantSetTokenConfigPermissions(governance);
        _allowlistTokenConfig(IERC20(tokenB), TokenType.STANDARD, IRateProvider(address(0)), false);
    }

    function _grantSetTokenConfigPermissions(address admin) internal {
        BasicAuthorizerMock authorizer = BasicAuthorizerMock(address(factory.getAuthorizer()));
        bytes32 actionId = factory.getActionId(WeightedPool8020Factory.allowlistTokenConfig.selector);
        authorizer.grantRole(actionId, admin);
    }

    function _allowlistTokenConfig(
        IERC20 lowWeightToken,
        TokenType tokenType,
        IRateProvider rateProviderValue,
        bool yieldFeeExempt
    ) internal {
        TokenConfig memory lowWeightTokenConfig;
        lowWeightTokenConfig.token = lowWeightToken;
        lowWeightTokenConfig.tokenType = tokenType;
        lowWeightTokenConfig.rateProvider = rateProviderValue;
        lowWeightTokenConfig.yieldFeeExempt = yieldFeeExempt;
        vm.prank(governance);
        factory.allowlistTokenConfig(lowWeightTokenConfig);
    }

    function _createPool(IERC20 highToken, IERC20 lowToken) private returns (WeightedPool) {
        PoolRoleAccounts memory roleAccounts;

        return WeightedPool(factory.create(highToken, lowToken, roleAccounts, DEFAULT_SWAP_FEE));
    }

    function testFactoryPausedState() public view {
        uint32 pauseWindowDuration = factory.getPauseWindowDuration();
        assertEq(pauseWindowDuration, 365 days);
    }

    function testTokenConfigReverts() public {
        vm.expectRevert(WeightedPool8020Factory.TokenConfigNotAllowlisted.selector);
        _createPool(tokenA, tokenC);
    }

    function testTokenConfigSetterAndGetter() public {
        TokenConfig memory expectedTokenConfig;
        expectedTokenConfig.token = tokenC;
        expectedTokenConfig.tokenType = TokenType.WITH_RATE;
        expectedTokenConfig.rateProvider = IRateProvider(address(10));
        expectedTokenConfig.yieldFeeExempt = true;

        vm.expectEmit(true, true, true, true, address(factory));
        emit TokenConfigAllowlisted(expectedTokenConfig);

        _allowlistTokenConfig(tokenC, TokenType.WITH_RATE, IRateProvider(address(10)), true);

        TokenConfig memory tokenConfig = factory.getTokenConfig(tokenC);
        assertEq(address(tokenConfig.token), address(expectedTokenConfig.token));
        assertEq(uint256(tokenConfig.tokenType), uint256(expectedTokenConfig.tokenType));
        assertEq(address(tokenConfig.rateProvider), address(expectedTokenConfig.rateProvider));
        assertEq(tokenConfig.yieldFeeExempt, expectedTokenConfig.yieldFeeExempt);

        TokenConfig memory nonAllowlistedConfig = factory.getTokenConfig(tokenA);
        assertEq(address(nonAllowlistedConfig.token), address(0));
    }

    function testPoolFetching() public {
        WeightedPool pool = _createPool(tokenA, tokenB);
        address expectedPoolAddress = factory.getPool(tokenA, tokenB);

        uint256[] memory poolWeights = pool.getNormalizedWeights();
        uint256[] memory minTokenBalances = new uint256[](2);
        (uint256 aIdx, uint256 bIdx) = tokenA < tokenB ? (0, 1) : (1, 0);
        minTokenBalances[aIdx] = _getMinTokenBalance(address(tokenA));
        minTokenBalances[bIdx] = _getMinTokenBalance(address(tokenB));

        bytes memory poolArgs = abi.encode(
            WeightedPool.NewPoolParams({
                name: "Balancer 80 TKNA 20 TKNB",
                symbol: "B-80TKNA-20TKNB",
                numTokens: 2,
                normalizedWeights: poolWeights,
                version: "8020Pool v1",
                minTokenBalances: minTokenBalances
            }),
            vault
        );

        bytes32 salt = keccak256(abi.encode(block.chainid, tokenA, tokenB));
        address deploymentAddress = factory.getDeploymentAddress(poolArgs, salt);

        assertEq(address(pool), expectedPoolAddress, "Wrong pool address");
        assertEq(deploymentAddress, expectedPoolAddress, "Wrong deployment address");
    }

    function testPoolCreation() public {
        (uint256 highWeightIdx, uint256 lowWeightIdx) = tokenA > tokenB ? (1, 0) : (0, 1);

        WeightedPool pool = _createPool(tokenA, tokenB);

        uint256[] memory poolWeights = pool.getNormalizedWeights();
        assertEq(poolWeights[highWeightIdx], 80e16, "Higher weight token is not 80%");
        assertEq(poolWeights[lowWeightIdx], 20e16, "Lower weight token is not 20%");
        assertEq(pool.name(), "Balancer 80 TKNA 20 TKNB", "Wrong pool name");
        assertEq(pool.symbol(), "B-80TKNA-20TKNB", "Wrong pool symbol");
    }

    function testPoolWithInvertedWeights() public {
        WeightedPool pool = _createPool(tokenA, tokenB);

        _allowlistTokenConfig(tokenA, TokenType.STANDARD, IRateProvider(address(0)), true);

        WeightedPool invertedPool = _createPool(tokenB, tokenA);

        assertNotEq(
            address(pool),
            address(invertedPool),
            "Pools with same tokens but different weights should be different"
        );
    }

    function testPoolUniqueness() public {
        _createPool(tokenA, tokenB);

        vm.expectRevert(Errors.FailedDeployment.selector);
        _createPool(tokenA, tokenB);

        // Trying to create the same pool with same highWeightToken but different token config should revert
        _allowlistTokenConfig(tokenB, TokenType.WITH_RATE, IRateProvider(address(10)), true);

        vm.expectRevert(Errors.FailedDeployment.selector);
        _createPool(tokenA, tokenB);
    }

    /// forge-config: default.fuzz.runs = 10
    function testPoolCrossChainProtection__Fuzz(uint16 chainId) public {
        // Eliminate the test chain.
        vm.assume(chainId != 31337);

        vm.prank(alice);
        WeightedPool poolMainnet = _createPool(tokenA, tokenB);

        vm.chainId(chainId);

        vm.prank(alice);
        WeightedPool poolL2 = _createPool(tokenA, tokenB);

        // Same salt parameters, should still be different because of the chainId.
        assertNotEq(address(poolL2), address(poolMainnet), "L2 and mainnet pool addresses are equal");
    }

    // Duplicated from BaseVaultTest, since this only inherits from Test.
    function _getMinTokenBalance(address token) internal view returns (uint256) {
        uint256 absoluteMin = MinTokenBalanceLib.ABSOLUTE_MIN_TOKEN_BALANCE;

        uint256 tokenDecimals = IERC20Metadata(token).decimals();
        uint256 atomicUnitFloor = 10 ** (18 - tokenDecimals);

        return Math.max(absoluteMin, atomicUnitFloor);
    }
}
