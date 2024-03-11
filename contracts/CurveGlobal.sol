// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.8.19;

enum VaultType {
    LEGACY,
    DEFAULT,
    AUTOMATED
}

interface IDetails {
    // get details from curve
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);
}

interface IGaugeController {
    // check if gauge has weight
    function get_gauge_weight(address) external view returns (uint256);
}

interface IVoter {
    // get details from our curve voter
    function strategy() external view returns (address);
}

interface IProxy {
    function approveStrategy(address gauge, address strategy) external;

    function strategies(address gauge) external view returns (address);
}

interface IRegistry {
    function newEndorsedVault(
        address _asset,
        string memory _name,
        string memory _symbol,
        address _roleManager,
        uint256 _profitMaxUnlockTime
    ) external returns (address);

    function latestVaultOfType(
        address token,
        uint256 _type
    ) external view returns (address);
}

interface IPoolManager {
    function addPool(address _gauge) external returns (bool);
}

interface IPoolRegistry {
    function poolInfo(
        uint256 _pid
    )
        external
        view
        returns (
            address implementation,
            address stakingAddress,
            address stakingToken,
            address rewardsAddress,
            uint8 isActive
        );

    function poolLength() external view returns (uint256);
}

interface IStakingToken {
    function convexPoolId() external view returns (uint256);
}

interface ICurveGauge {
    function deposit(uint256) external;

    function balanceOf(address) external view returns (uint256);

    function withdraw(uint256) external;

    function claim_rewards() external;

    function reward_tokens(uint256) external view returns (address); //v2

    function rewarded_token() external view returns (address); //v1

    function lp_token() external view returns (address);
}

interface IStrategy {
    function cloneStrategyCurveBoosted(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _tradeFactory,
        address _proxy,
        address _gauge
    ) external returns (address newStrategy);
    
    function cloneStrategyConvex(
        address _vault,
        address _strategist,
        address _rewards,
        address _keeper,
        address _tradeFactory,
        uint256 _pid,
        uint256 _harvestProfitMinInUsdc,
        uint256 _harvestProfitMaxInUsdc,
        address _booster,
        address _convexToken
    ) external returns (address newStrategy);

    function setVoter(address _curveVoter) external;

    function setVoters(address _curveVoter, address _convexVoter) external;

    function setLocalKeepCrvs(uint256 _keepCrv, uint256 _keepCvx) external;

    function setLocalKeepCrv(uint256 _keepCrv) external;

    function setHealthCheck(address) external;

    function setBaseFeeOracle(address) external;
}

interface IBooster {
    function gaugeMap(address) external view returns (bool);

    // deposit into convex, receive a tokenized deposit.  parameter to stake immediately (we always do this).
    function deposit(
        uint256 _pid,
        uint256 _amount,
        bool _stake
    ) external returns (bool);

    // burn a tokenized deposit (Convex deposit tokens) to receive curve lp tokens back
    function withdraw(uint256 _pid, uint256 _amount) external returns (bool);

    function poolLength() external view returns (uint256);

    // give us info about a pool based on its pid
    function poolInfo(
        uint256
    ) external view returns (address, address, address, address, address, bool);
}

interface Vault {
    function setGovernance(address) external;

    function setManagement(address) external;

    function managementFee() external view returns (uint256);

    function setManagementFee(uint256) external;

    function performanceFee() external view returns (uint256);

    function setPerformanceFee(uint256) external;

    function setDepositLimit(uint256) external;

    function addStrategy(address, uint256, uint256, uint256, uint256) external;
}

contract CurveGlobal {
    event NewAutomatedVault(
        uint256 indexed category,
        address indexed lpToken,
        address gauge,
        address indexed vault,
        address curveStrategy,
        address convexStrategy
    );

    /* ========== STATE VARIABLES ========== */

    /// @notice This is a list of all vaults deployed by this factory.
    address[] public deployedVaults;

    /// @notice This is specific to the protocol we are deploying automated vaults for.
    /// @dev 0 for curve, 1 for balancer. This is a subcategory within our vault type AUTOMATED on the registry.
    uint256 public constant CATEGORY = 0;

    /// @notice Owner of the factory.
    address public owner;

    // @notice Pending owner of the factory.
    /// @dev Must accept before becoming owner.
    address public pendingOwner;

    /// @notice Address of our Convex token.
    address public constant CVX = 0x4e3FBD56CD56c3e72c1403e103b45Db9da5B9D2B;

    /// @notice Address of our Convex pool manager.
    /// @dev Used to add new pools to Convex.
    address public convexPoolManager =
        0xc461E1CE3795Ee30bA2EC59843d5fAe14d5782D5;

    /// @notice Yearn's V3 vault registry address.
    IRegistry public registry;

    /// @notice Address of Convex's deposit contract, aka booster.
    IBooster public booster =
        IBooster(0xF403C135812408BFbE8713b5A23a04b3D48AAE31);

    /// @notice Address to use for vault governance.
    address public governance = 0xFEB4acf3df3cDEA7399794D0869ef76A6EfAff52;

    /// @notice Address to use for vault management.
    address public management = 0x16388463d60FFE0661Cf7F1f31a7D658aC790ff7;

    /// @notice Address to use for vault guardian.
    address public guardian = 0x846e211e8ba920B353FB717631C015cf04061Cc9;

    /// @notice Address to use for vault and strategy rewards.
    address public treasury = 0x93A62dA5a14C80f265DAbC077fCEE437B1a0Efde;

    /// @notice Address to use for strategy keepers.
    address public keeper = 0x0D26E894C2371AB6D20d99A65E991775e3b5CAd7;

    /// @notice Address to use for strategy health check.
    address public healthCheck = 0xDDCea799fF1699e98EDF118e0629A974Df7DF012;

    /// @notice Address to use for strategy trade factory.
    address public tradeFactory = 0xb634316E06cC0B358437CbadD4dC94F1D3a92B3b;

    /// @notice Address to use for our network's base fee oracle.
    address public baseFeeOracle = 0x1E7eFAbF282614Aa2543EDaA50517ef5a23c868b;

    /// @notice Address of our Curve strategy factory.
    /// @dev This cannot be zero address for Curve vaults.
    address public curveStratFactory;

    /// @notice Address of our Convex strategy factory.
    /// @dev If zero address, then factory will produce vaults with only Curve strategies.
    address public convexStratFactory;

    /// @notice Default performance fee for our factory vaults (in basis points).
    uint256 public performanceFee = 1_000;

    /// @notice Default management fee for our factory vaults (in basis points).
    uint256 public managementFee = 0;

    /// @notice Default deposit limit on our factory vaults. Set to a large number.
    uint256 public depositLimit = 10_000_000_000_000 * 1e18;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _registry,
        address _curveStratFactory,
        address _convexStratFactory,
        address _owner
    ) {
        registry = IRegistry(_registry);
        curveStratFactory = _curveStratFactory;
        convexStratFactory = _convexStratFactory;
        owner = _owner;
        pendingOwner = _owner;
    }

    /* ========== STATE VARIABLE SETTERS ========== */

    /// @notice Set the new owner of the factory.
    /// @dev Must be called by current owner.
    ///  New owner will have to accept before transition is complete.
    /// @param newOwner Address of new owner.
    function setOwner(address newOwner) external {
        if (msg.sender != owner) {
            revert();
        }
        pendingOwner = newOwner;
    }

    /// @notice Accept ownership of the factory.
    /// @dev Must be called by pending owner.
    function acceptOwner() external {
        if (msg.sender != pendingOwner) {
            revert();
        }
        owner = pendingOwner;
    }

    /// @notice Set the yearn vault registry address for the factory.
    /// @dev Must be called by owner.
    /// @param _registry Address of yearn vault registry.
    function setRegistry(address _registry) external {
        if (msg.sender != owner) {
            revert();
        }
        registry = IRegistry(_registry);
    }

    /// @notice Set the convex booster address for the factory.
    /// @dev Must be called by owner.
    /// @param _booster Address of convex booster.
    function setBooster(address _booster) external {
        if (msg.sender != owner) {
            revert();
        }
        booster = IBooster(_booster);
    }

    /// @notice Set the vault governance address for the factory.
    /// @dev Must be called by owner.
    /// @param _governance Address of default vault governance.
    function setGovernance(address _governance) external {
        if (msg.sender != owner) {
            revert();
        }
        governance = _governance;
    }

    /// @notice Set the vault management address for the factory.
    /// @dev Must be called by owner.
    /// @param _management Address of default vault management.
    function setManagement(address _management) external {
        if (msg.sender != owner) {
            revert();
        }
        management = _management;
    }

    /// @notice Set the vault guardian address for the factory.
    /// @dev Must be called by owner.
    /// @param _guardian Address of default vault guardian.
    function setGuardian(address _guardian) external {
        if (msg.sender != owner) {
            revert();
        }
        guardian = _guardian;
    }

    /// @notice Set the vault treasury/rewards address for the factory.
    /// @dev Must be called by owner. Vault rewards will flow here.
    /// @param _treasury Address of default vault rewards.
    function setTreasury(address _treasury) external {
        if (msg.sender != owner) {
            revert();
        }
        treasury = _treasury;
    }

    /// @notice Set the vault keeper address for the factory.
    /// @dev Must be called by owner or management.
    /// @param _keeper Address of default vault keeper.
    function setKeeper(address _keeper) external {
        if (!(msg.sender == owner || msg.sender == management)) {
            revert();
        }
        keeper = _keeper;
    }

    /// @notice Set the strategy base fee oracle address for the factory.
    /// @dev Must be called by owner or management. Oracle passes current network base
    ///  fee so strategy can avoid harvesting during periods of network congestion.
    /// @param _baseFeeOracle Address of default base fee oracle for strategies.
    function setBaseFeeOracle(address _baseFeeOracle) external {
        if (!(msg.sender == owner || msg.sender == management)) {
            revert();
        }
        baseFeeOracle = _baseFeeOracle;
    }

    /// @notice Set the vault deposit limit for the factory.
    /// @dev Must be called by owner or management.
    /// @param _depositLimit Default deposit limit for vaults created by factory.
    function setDepositLimit(uint256 _depositLimit) external {
        if (!(msg.sender == owner || msg.sender == management)) {
            revert();
        }
        depositLimit = _depositLimit;
    }

    /// @notice Set the Convex strategy factory address.
    /// @dev Must be called by owner.
    /// @param _convexStratFactory Address of latest Convex strategy factory.
    function setConvexStratFactory(
        address _convexStratFactory
    ) external {
        if (msg.sender != owner) {
            revert();
        }
        convexStratFactory = _convexStratFactory;
    }

    /// @notice Set the Curve boosted strategy factory address.
    /// @dev Must be called by owner.
    /// @param _curveStratFactory Address of latest Curve boosted strategy factory.
    function setCurveStratFactory(
        address _curveStratFactory
    ) external {
        if (msg.sender != owner) {
            revert();
        }
        curveStratFactory = _curveStratFactory;
    }

    /// @notice Set the performance fee (percentage of profit) deducted from each harvest.
    /// @dev Must be called by owner. Fees are collected as minted vault shares.
    ///  Default amount is 10%.
    /// @param _performanceFee The percentage of profit from each harvest that is sent to treasury (out of 10,000).
    function setPerformanceFee(uint256 _performanceFee) external {
        if (msg.sender != owner) {
            revert();
        }
        if (_performanceFee > 5_000) {
            revert();
        }
        performanceFee = _performanceFee;
    }

    /// @notice Set the management fee (as a percentage of TVL) assessed on factory vaults.
    /// @dev Must be called by owner. Fees are collected as minted vault shares on each harvest.
    ///  Default amount is 0%.
    /// @param _managementFee The percentage fee assessed on TVL (out of 10,000).
    function setManagementFee(uint256 _managementFee) external {
        if (msg.sender != owner) {
            revert();
        }
        if (_managementFee > 1_000) {
            revert();
        }
        managementFee = _managementFee;
    }

    /* ========== VIEWS ========== */

    /// @notice View all vault addresses deployed by this factory.
    /// @return Array of all deployed factory vault addresses.
    function allDeployedVaults() external view returns (address[] memory) {
        return deployedVaults;
    }

    /// @notice Number of vaults deployed by this factory.
    /// @return Number of vaults deployed by this factory.
    function numVaults() external view returns (uint256) {
        return deployedVaults.length;
    }

    /// @notice Check whether, for a given gauge address, it is possible to permissionlessly
    ///  create a vault for corresponding LP token.
    /// @param _gauge The gauge address to check.
    /// @return Whether or not vault can be created permissionlessly.
    function canCreateVaultPermissionlessly(
        address _gauge
    ) public view returns (bool) {
        address lptoken = ICurveGauge(_gauge).lp_token();
        return registry.numEndorsedVaults(lptoken) == 0;
    }

    /// @notice Check if our strategy proxy has already approved a strategy for a given gauge.
    /// @dev Because this pulls our latest proxy from the voter, be careful if ever updating our curve voter,
    ///  though in reality our curve voter should always stay the same.
    /// @param _gauge The gauge address to check on our strategy proxy.
    /// @return Whether or not gauge already has a curve voter strategy setup.
    function doesStrategyProxyHaveGauge(
        address _gauge
    ) public view returns (bool) {
        address strategyProxy = getProxy();
        return IProxy(strategyProxy).strategies(_gauge) != address(0);
    }

    /// @notice Find the Convex pool id (pid) for a given Curve gauge.
    /// @dev Will return max uint if no pid exists for a gauge.
    /// @param _gauge The gauge address to check.
    /// @return pid The Convex pool id for the specified Curve gauge.
    function getPid(address _gauge) public view returns (uint256 pid) {
        IBooster _booster = booster;
        if (!_booster.gaugeMap(_gauge)) {
            return type(uint256).max;
        }

        for (uint256 i = _booster.poolLength(); i > 0; --i) {
            //we start at the end and work back for most recent
            (, , address gauge, , , ) = _booster.poolInfo(i - 1);

            if (_gauge == gauge) {
                return i - 1;
            }
        }
    }

    /// @notice Check our current Curve strategy proxy via our Curve voter.
    /// @return proxy Address of our current Curve strategy proxy.
    function getProxy() public view returns (address proxy) {
        proxy = IVoter(curveVoter).strategy();
    }

    /* ========== CORE FUNCTIONS ========== */

    /// @notice Deploy a factory Curve vault for a given Curve gauge.
    /// @dev Permissioned users may set custom name and symbol or deploy if a legacy version already exists.
    ///  Must be called by owner or management.
    /// @param _gauge Address of the Curve gauge to deploy a new vault for.
    /// @param _name Name of the new vault.
    /// @param _symbol Symbol of the new vault token.
    /// @return vault Address of the new vault.
    /// @return curveStrategy Address of the vault's Curve boosted strategy.
    /// @return convexStrategy Address of the vault's Convex strategy, if created.
    function createNewVaultsAndStrategiesPermissioned(
        address _gauge,
        string memory _name,
        string memory _symbol
    )
        external
        returns (
            address vault,
            address curveStrategy,
            address convexStrategy
        )
    {
        if (!(msg.sender == owner || msg.sender == management)) {
            revert();
        }

        return _createNewVaultsAndStrategies(_gauge, true, _name, _symbol);
    }

    /// @notice Deploy a factory Curve vault for a given Curve gauge permissionlessly.
    /// @dev This may be called by anyone. Note that if a vault already exists for the given gauge,
    ///  then this call will revert.
    /// @param _gauge Address of the Curve gauge to deploy a new vault for.
    /// @return vault Address of the new vault.
    /// @return curveStrategy Address of the vault's Curve boosted strategy.
    /// @return convexStrategy Address of the vault's Convex strategy, if created.
    function createNewVaultsAndStrategies(
        address _gauge
    )
        external
        returns (
            address vault,
            address curveStrategy,
            address convexStrategy
        )
    {
        return
            _createNewVaultsAndStrategies(_gauge, false, "default", "default");
    }

    // create a new vault along with strategies to match
    function _createNewVaultsAndStrategies(
        address _gauge,
        bool _permissionedUser,
        string memory _name,
        string memory _symbol
    )
        internal
        returns (
            address vault,
            address curveStrategy,
            address convexStrategy
        )
    {
        // if a vault already exists, only permissioned users can deploy another
        if (!_permissionedUser) {
            require(
                canCreateVaultPermissionlessly(_gauge),
                "Vault already exists"
            );
        }
        address lptoken = ICurveGauge(_gauge).lp_token();

        if (_permissionedUser) {
            // allow trusted users to input the name and symbol or deploy a factory version of a legacy vault
            vault = _createCustomVault(lptoken, _name, _symbol);
        } else {
            // anyone can create a vault, but it will have an auto-generated name and symbol
            vault = _createStandardVault(lptoken);
        }

        // setup our fees, deposit limit, gov, etc
        _setupVaultParams(vault);

        // setup our strategies as needed
        curveStrategy = _addCurveStrategy(_vault, _gauge);
        convexStrategy = _addConvexStrategy(_vault, _gauge);

        emit NewAutomatedVault(
            CATEGORY,
            lptoken,
            _gauge,
            vault,
            curveStrategy,
            convexStrategy
        );
    }

    // permissioned users may pass custom name and symbol inputs
    function _createCustomVault(
        address _lptoken,
        string memory _name,
        string memory _symbol
    ) internal returns (address vault) {
        vault = registry.newEndorsedVault(
            _lptoken,
            _name,
            _symbol,
            guardian,
            86400
        );
    }

    // standard vaults create default name and symbols using on-chain data
    function _createStandardVault(
        address _lptoken
    ) internal returns (address vault) {
        vault = registry.newEndorsedVault(
            _lptoken,
            string(
                abi.encodePacked(
                    "Curve ",
                    IDetails(address(_lptoken)).symbol(),
                    " V3 Factory yVault"
                )
            ),
            string(
                abi.encodePacked(
                    "yvCurve-",
                    IDetails(address(_lptoken)).symbol(),
                    "-f"
                )
            ),
            guardian,
            86400
        );
    }

    // set vault management, gov, deposit limit, and fees
    function _setupVaultParams(address _vault) internal {
        // record our new vault for posterity
        deployedVaults.push(_vault);

        Vault v = Vault(_vault);
        v.setManagement(management);

        // set governance to ychad who needs to accept before it is finalised. until then governance is this factory
        v.setGovernance(governance);
        v.setDepositLimit(depositLimit);

        if (v.managementFee() != managementFee) {
            v.setManagementFee(managementFee);
        }
        if (v.performanceFee() != performanceFee) {
            v.setPerformanceFee(performanceFee);
        }
    }

    // deploy and attach a new curve strategy using the latest curve strategy factory
    function _addCurveStrategy(
        address _vault,
        address _gauge
    ) internal returns (address curveStrategy) {
        // the factory will just pass the gauge on to the tokenized strategy factory. we start unboosted, but at some 
        // point in the future will move to veCRV boosted positions. 
        
        // create the curve voter strategy
        curveStrategy = IStrategyFactory(curveStratFactory)
            .cloneCurveStrategy(
                _vault,
                _gauge
            );
        
        Vault(_vault).add_strategy(curveStrategy);
    }

    // deploy and attach a new convex strategy using the latest convex strategy factory
    function _addConvexStrategy(
        address _vault,
        address _gauge
    ) internal returns (address convexStrategy) {
        if (convexStratFactory == address(0)) {
            return;
        }

        // get convex pid. if no pid we need to deploy the convex pool first
        uint256 pid = getPid(_gauge);
        if (pid == type(uint256).max) {
            revert("Deploy Convex pool first");
        }
        
        convexStrategy = IStrategy(convexStratFactory)
            .cloneStrategyConvex(
                _vault,
                pid
            );
        
        Vault(_vault).add_strategy(convexStrategy);
    }
}
