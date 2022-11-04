// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.15;
pragma experimental ABIEncoderV2;

// These are the core Yearn libraries
import "@openzeppelin/contracts/math/Math.sol";

import "./interfaces/curve.sol";
import "@yearnvaults/contracts/BaseStrategy.sol";

interface ITradeFactory {
    function enable(address, address) external;

    function disable(address, address) external;
}

interface IFeedRegistry {
    function getFeed(address, address) external view returns (address);

    function latestRoundData(address, address) external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

interface IBaseFee {
    function isCurrentBaseFeeAcceptable() external view returns (bool);
}

interface IConvexRewards {
    // strategy's staked balance in the synthetix staking contract
    function balanceOf(address account) external view returns (uint256);

    // read how much claimable CRV a strategy has
    function earned(address account) external view returns (uint256);

    // stake a convex tokenized deposit
    function stake(uint256 _amount) external returns (bool);

    // withdraw to a convex tokenized deposit, probably never need to use this
    function withdraw(uint256 _amount, bool _claim) external returns (bool);

    // withdraw directly to curve LP token, this is what we primarily use
    function withdrawAndUnwrap(uint256 _amount, bool _claim)
        external
        returns (bool);

    // claim rewards, with an option to claim extra rewards or not
    function getReward(address _account, bool _claimExtras)
        external
        returns (bool);

    // check if we have rewards on a pool
    function extraRewardsLength() external view returns (uint256);

    // if we have rewards, see what the address is
    function extraRewards(uint256 _reward) external view returns (address);

    // read our rewards token
    function rewardToken() external view returns (address);

    // check our reward period finish
    function periodFinish() external view returns (uint256);
}

interface IDetails {
    // get details from curve
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);
}

interface IConvexDeposit {
    // deposit into convex, receive a tokenized deposit.  parameter to stake immediately (we always do this).
    function deposit(
        uint256 _pid,
        uint256 _amount,
        bool _stake
    ) external returns (bool);

    // burn a tokenized deposit (Convex deposit tokens) to receive curve lp tokens back
    function withdraw(uint256 _pid, uint256 _amount) external returns (bool);

    function poolLength() external view returns (uint256);

    function crv() external view returns (address);

    // give us info about a pool based on its pid
    function poolInfo(uint256)
        external
        view
        returns (
            address,
            address,
            address,
            address,
            address,
            bool
        );
}

contract StrategyCurveBoostedFactoryClonable is BaseStrategy {
    /* ========== STATE VARIABLES ========== */
    // these should stay the same across different wants.

    // curve infrastructure contracts
    ICurveStrategyProxy public proxy; // Below we set it to Yearn's Updated v4 StrategyProxy
    address public gauge; // Curve gauge contract, most are tokenized, held by Yearn's voter
    uint256 public localKeepCRV;

    address public constant voter = 0xF147b8125d2ef93FB6965Db97D6746952a133934; // Yearn's veCRV voter
    uint256 internal constant FEE_DENOMINATOR = 10000; // this means all of our fee values are in basis points

    IERC20 public crv;

    /* ========== STATE VARIABLES ========== */
    // these will likely change across different wants.

    string internal stratName; // we use this to be able to adjust our strategy's name

    // convex-specific variables
    bool public claimRewards; // boolean if we should always claim rewards when withdrawing, usually withdrawAndUnwrap (generally this should be false)

    bool public checkEarmark; // this determines if we should check if we need to earmark rewards before harvesting

    address public tradeFactory;

    // rewards token info. we can have more than 1 reward token
    address[] public rewardsTokens;

    // check for cloning. Will only be true on the original deployed contract and not on the clones
    bool internal isOriginal = true;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _vault,
        address _gauge,
        address _tradeFactory,
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax
    ) public BaseStrategy(_vault) {
        _initializeStrat(
            _gauge,
            _tradeFactory,
            _harvestProfitMin,
            _harvestProfitMax
        );
    }

    /* ========== CLONING ========== */

    event Cloned(address indexed clone);

    // we use this to clone our original strategy to other vaults
    function cloneStrategyCurveBoosted(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _gauge,
        address _tradeFactory,
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax
    ) external returns (address newStrategy) {
        if(!isOriginal) {
            revert();
        }

        // Copied from https://github.com/optionality/clone-factory/blob/master/contracts/CloneFactory.sol
        bytes20 addressBytes = bytes20(address(this));
        assembly {
            // EIP-1167 bytecode
            let clone_code := mload(0x40)
            mstore(
                clone_code,
                0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000
            )
            mstore(add(clone_code, 0x14), addressBytes)
            mstore(
                add(clone_code, 0x28),
                0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000
            )
            newStrategy := create(0, clone_code, 0x37)
        }

        StrategyCurveBoostedFactoryClonable(newStrategy).initialize(
            _vault,
            _strategist,
            _rewards,
            _keeper,
            _gauge,
            _tradeFactory,
            _harvestProfitMin,
            _harvestProfitMax,
        );

        emit Cloned(newStrategy);
    }

    // this will only be called by the clone function above
    function initialize(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _gauge,
        address _tradeFactory,
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax
    ) public {
        _initialize(_vault, _strategist, _rewards, _keeper);
        _initializeStrat(
            _gauge,
            _tradeFactory,
            _harvestProfitMin,
            _harvestProfitMax,
        );
    }

    // this is called by our original strategy, as well as any clones
    function _initializeStrat(
        address _gauge,
        address _tradeFactory,
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax,
    ) internal {
        // make sure that we haven't initialized this before
        if(address(tradeFactory) != address(0)) {
            revert();  // already initialized.
        }

        // want = Curve LP
        want.approve(address(proxy), type(uint256).max);

        // set our curve gauge contract
        gauge = address(_gauge);

        // need to set our proxy when cloning since it's not a constant **************** ADD THIS TO GLOBAL SETTINGS INSTEAD
        proxy = ICurveStrategyProxy(0xA420A63BbEFfbda3B147d0585F1852C358e2C152);

        // harvest profit max set to 25k usdt. will trigger harvest in this situation
        harvestProfitMin = _harvestProfitMin;
        harvestProfitMax = _harvestProfitMax;

        crv = IERC20(dp.crv());

        if(address(lptoken) != address(want)) {
            revert();
        }

        tradeFactory = _tradeFactory;

        _updateRewards();
        _setUpTradeFactory();

        // set our strategy's name
        stratName = string(
            abi.encodePacked(
                IDetails(address(want)).name(),
                " Auto-Compounding ",
                IDetails(address(convexToken)).symbol(),
                " Strategy"
            )
        );
    }

    function _setUpTradeFactory() internal {
        //approve and set up trade factory
        address _tradeFactory = tradeFactory;
        address _want = address(want);

        ITradeFactory tf = ITradeFactory(_tradeFactory);
        crv.approve(_tradeFactory, type(uint256).max);
        tf.enable(address(crv), _want);

        //enable for all rewards tokens too
        uint256 rLength = rewardsTokens.length;
        for (uint256 i; i < rLength; ++i) {
            address _rewardsToken = rewardsTokens[i];
            IERC20(_rewardsToken).approve(
                _tradeFactory,
                type(uint256).max
            );
            tf.enable(_rewardsToken, _want);
        }

        convexToken.approve(_tradeFactory, type(uint256).max);
        tf.enable(address(convexToken), _want);
    }

    /* ========== FUNCTIONS ========== */

    function prepareReturn(uint256 _debtOutstanding)
        internal
        override
        returns (
            uint256 _profit,
            uint256 _loss,
            uint256 _debtPayment
        )
    {
        // this claims our CRV, CVX, and any extra tokens like SNX or ANKR. no harm leaving this true even if no extra rewards currently
        // rewards will be converted later with mev protection by yswaps (tradeFactory)
        rewardsContract.getReward(address(this), true);

        uint256 _localKeepCRV = localKeepCRV;
        address _curveVoter = curveVoter;
        if (_localKeepCRV > 0 && _curveVoter != address(0)) {
            uint256 crvBalance = crv.balanceOf(address(this));
            uint256 _sendToVoter =
                crvBalance.mul(_localKeepCRV).div(FEE_DENOMINATOR);
            if (_sendToVoter > 0) {
                crv.safeTransfer(_curveVoter, _sendToVoter);
            }
        }

        uint256 _localKeepCVX = localKeepCVX;
        address _convexVoter = convexVoter;
        if (_localKeepCVX > 0 && _convexVoter != address(0)) {
            uint256 cvxBalance = convexToken.balanceOf(address(this));
            uint256 _sendToVoter =
                cvxBalance.mul(_localKeepCVX).div(FEE_DENOMINATOR);
            if (_sendToVoter > 0) {
                convexToken.safeTransfer(_convexVoter, _sendToVoter);
            }
        }

        // serious loss should never happen, but if it does (for instance, if Curve is hacked), let's record it accurately
        uint256 assets = estimatedTotalAssets();
        uint256 debt = vault.strategies(address(this)).totalDebt;

        // if assets are greater than debt, things are working great!
        if (assets >= debt) {
            _profit = assets - debt;
            _debtPayment = _debtOutstanding;

            uint256 toFree = _profit.add(_debtPayment);

            //freed is math.min(wantBalance, toFree)
            (uint256 freed, ) = liquidatePosition(toFree);

            if (toFree > freed) {
                if (_debtPayment > freed) {
                    _debtPayment = freed;
                    _profit = 0;
                } else {
                    _profit = freed - _debtPayment;
                }
            }
        }
        // if assets are less than debt, we are in trouble. should never happen. dont worry about withdrawing here just report profit
        else {
            _loss = debt - assets;
        }

        // we're done harvesting, so reset our trigger if we used it
        forceHarvestTriggerOnce = false;
    }

    // migrate our want token to a new strategy if needed
    // also send over any CRV or CVX that is claimed; for migrations we definitely want to claim
    function prepareMigration(address _newStrategy) internal override {
        uint256 stakedBal = stakedBalance();
        
        if (stakedBal > 0) {
            rewardsContract.withdrawAndUnwrap(stakedBal, claimRewards);
        }

        uint256 crvBal = crv.balanceOf(address(this));
        uint256 cvxBal = convexToken.balanceOf(address(this));

        if (crvBal > 0){
            crv.safeTransfer(_newStrategy, crvBal);
        }
        if (cvxBal > 0){
            convexToken.safeTransfer(_newStrategy, cvxBal);
        }
    }

    /* ========== KEEP3RS ========== */
    // use this to determine when to harvest automagically
    function harvestTrigger(uint256 callCostinEth)
        public
        view
        override
        returns (bool)
    {
        // only check if we need to earmark on vaults we know are problematic
        if (checkEarmark) {
            // don't harvest if we need to earmark convex rewards
            if (needsEarmarkReward()) {
                return false;
            }
        }

        // harvest if we have a profit to claim at our upper limit without considering gas price
        uint256 claimableProfit = claimableProfitInUsdt();
        if (claimableProfit > harvestProfitMax) {
            return true;
        }

        // check if the base fee gas price is higher than we allow. if it is, block harvests.
        if (!isBaseFeeAcceptable()) {
            return false;
        }

        // trigger if we want to manually harvest, but only if our gas price is acceptable
        if (forceHarvestTriggerOnce) {
            return true;
        }

        // harvest if we have a sufficient profit to claim, but only if our gas price is acceptable
        if (claimableProfit > harvestProfitMin) {
            return true;
        }

        // otherwise, we don't harvest
        return false;
    }

    // only checks crv rewards. do we need to also check convexToken?
    //Returns the expected value of the rewards in USDT, 1e6
    function claimableProfitInUsdt() public view returns (uint256) {
        (, int256 crvPrice,,,) = IFeedRegistry(0x47Fb2585D2C56Fe188D0E6ec628a38b74fCeeeDf).latestRoundData(
            address(crv),
            address(0x0000000000000000000000000000000000000348) // USD
        );

        //Get the latest oracle price for bal * amount of bal / (1e18 + 1e2) to adjust oracle price that is 1e8
        return uint256(crvPrice).mul(claimableBalance()).div(1e20);
    }

    // convert our keeper's eth cost into want, we don't need this anymore since we don't use baseStrategy harvestTrigger
    function ethToWant(uint256 _ethAmount)
        public
        view
        override
        returns (uint256)
    {}

    // check if someone needs to earmark rewards on convex before keepers harvest again
    function needsEarmarkReward() public view returns (bool needsEarmark) {
        // check if there is any CRV we need to earmark
        uint256 crvExpiry = rewardsContract.periodFinish();
        if (crvExpiry < block.timestamp) {
            return true;
        }
    }

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    // Use to add or update rewards
    // Rebuilds tradefactory too
    function updateRewards() external onlyGovernance {
        address tf = tradeFactory;
        _removeTradeFactoryPermissions();
        _updateRewards();

        tradeFactory = tf;
        _setUpTradeFactory();
    }

    function _updateRewards() internal {
        delete rewardsTokens; //empty the rewardsTokens and rebuild

        uint256 length = rewardsContract.extraRewardsLength();
        address _convexToken = address(convexToken);
        for (uint256 i; i < length; ++i) {
            address virtualRewardsPool = rewardsContract.extraRewards(i);
            address _rewardsToken =
                IConvexRewards(virtualRewardsPool).rewardToken();

            // we only need to approve the new token and turn on rewards if the extra rewards isn't CVX
            if (_rewardsToken != _convexToken) {
                rewardsTokens.push(_rewardsToken);
            }
        }
    }

    function updateLocalKeepCrvs(uint256 _keepCrv, uint256 _keepCvx)
        external
        onlyGovernance
    {
        if(_keepCrv > 10_000 || _keepCvx > 10_000) {
            revert();
        }

        localKeepCRV = _keepCrv;
        localKeepCVX = _keepCvx;
    }

    // Use to turn off extra rewards claiming and selling.
    function turnOffRewards() external onlyGovernance {
        delete rewardsTokens;
    }

    // determine whether we will check if our convex rewards need to be earmarked
    function setCheckEarmark(bool _checkEarmark) external onlyAuthorized {
        checkEarmark = _checkEarmark;
    }

    /* ========== VIEWS ========== */

    function name() external view override returns (string memory) {
        return stratName;
    }

    function stakedBalance() public view returns (uint256) {
        // how much want we have staked in Convex
        return rewardsContract.balanceOf(address(this));
    }

    function balanceOfWant() public view returns (uint256) {
        // balance of want sitting in our strategy
        return want.balanceOf(address(this));
    }

    function claimableBalance() public view returns (uint256) {
        // how much CRV we can claim from the staking contract
        return rewardsContract.earned(address(this));
    }

    function estimatedTotalAssets() public view override returns (uint256) {
        return balanceOfWant().add(stakedBalance());
    }

    /* ========== CONSTANT FUNCTIONS ========== */
    // these should stay the same across different wants.

    function adjustPosition(uint256 _debtOutstanding) internal override {
        if (emergencyExit) {
            return;
        }
        // Send all of our Curve pool tokens to be deposited
        uint256 _toInvest = balanceOfWant();
        // deposit into convex and stake immediately but only if we have something to invest
        if (_toInvest > 0) {
            IConvexDeposit(depositContract).deposit(pid, _toInvest, true);
        }
    }

    function liquidatePosition(uint256 _amountNeeded)
        internal
        override
        returns (uint256 _liquidatedAmount, uint256 _loss)
    {
        uint256 _wantBal = balanceOfWant();
        if (_amountNeeded > _wantBal) {
            uint256 _stakedBal = stakedBalance();
            if (_stakedBal > 0) {
                rewardsContract.withdrawAndUnwrap(
                    Math.min(_stakedBal, _amountNeeded - _wantBal),
                    claimRewards
                );
            }
            uint256 _withdrawnBal = balanceOfWant();
            _liquidatedAmount = Math.min(_amountNeeded, _withdrawnBal);
            _loss = _amountNeeded - _liquidatedAmount;
        } else {
            // we have enough balance to cover the liquidation available
            return (_amountNeeded, 0);
        }
    }

    // fire sale, get rid of it all!
    function liquidateAllPositions() internal override returns (uint256) {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            // don't bother withdrawing zero
            rewardsContract.withdrawAndUnwrap(_stakedBal, claimRewards);
        }
        return balanceOfWant();
    }

    // in case we need to exit into the convex deposit token, this will allow us to do that
    // make sure to check claimRewards before this step if needed
    // plan to have gov sweep convex deposit tokens from strategy after this
    function withdrawToConvexDepositTokens() external onlyAuthorized {
        uint256 _stakedBal = stakedBalance();
        if (_stakedBal > 0) {
            rewardsContract.withdraw(_stakedBal, claimRewards);
        }
    }

    // we don't want for these tokens to be swept out. We allow gov to sweep out cvx vault tokens; we would only be holding these if things were really, really rekt.
    function protectedTokens()
        internal
        view
        override
        returns (address[] memory)
    {}

    /* ========== SETTERS ========== */

    // These functions are useful for setting parameters of the strategy that may need to be adjusted.

    // We usually don't need to claim rewards on withdrawals, but might change our mind for migrations etc
    function setClaimRewards(bool _claimRewards) external onlyAuthorized {
        claimRewards = _claimRewards;
    }

    // This determines when we tell our keepers to start allowing harvests based on profit, and when to sell no matter what. this is how much in USDT we need to make. remember, 6 decimals!
    function setHarvestProfitNeeded(
        uint256 _harvestProfitMin,
        uint256 _harvestProfitMax
    ) external onlyAuthorized {
        harvestProfitMin = _harvestProfitMin;
        harvestProfitMax = _harvestProfitMax;
    }

    function updateTradeFactory(address _newTradeFactory)
        external
        onlyGovernance
    {
        if (tradeFactory != address(0)) {
            _removeTradeFactoryPermissions();
        }

        tradeFactory = _newTradeFactory;
        if (_newTradeFactory != address(0)) {
            _setUpTradeFactory();
        }
    }

    function updateVoters(address _curveVoter, address _convexVoter)
        external
        onlyGovernance
    {
        curveVoter = _curveVoter;
        convexVoter = _convexVoter;
    }

    // once this is called setupTradefactory must be called to get things working again
    function removeTradeFactoryPermissions() external onlyEmergencyAuthorized {
        _removeTradeFactoryPermissions();
    }

    function _removeTradeFactoryPermissions() internal {
        address _tradeFactory = tradeFactory;
        if (_tradeFactory == address(0)) {
            return;
        }
        ITradeFactory tf = ITradeFactory(_tradeFactory);

        address _want = address(want);
        crv.approve(_tradeFactory, 0);
        tf.disable(address(crv), _want);

        //disable for all rewards tokens too
        uint256 rLength = rewardsTokens.length;
        for (uint256 i; i < rLength; ++i) {
            address _rewardsToken = rewardsTokens[i];
            IERC20(_rewardsToken).approve(_tradeFactory, 0);
            tf.disable(_rewardsToken, _want);
        }

        convexToken.approve(_tradeFactory, 0);
        tf.disable(address(convexToken), _want);

        tradeFactory = address(0);
    }

    // This allows us to manually harvest with our keeper as needed
    function setForceHarvestTriggerOnce(bool _forceHarvestTriggerOnce)
        external
        onlyAuthorized
    {
        forceHarvestTriggerOnce = _forceHarvestTriggerOnce;
    }
}