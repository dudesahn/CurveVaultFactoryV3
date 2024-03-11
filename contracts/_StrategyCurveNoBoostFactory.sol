// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.18;

import {StrategyCurveNoBoost} from "./StrategyCurveNoBoost.sol";
import {IStrategyInterface} from "./interfaces/IStrategyInterface.sol";

contract StrategyCurveNoBoostFactory {
    address public management;
    address public sms;

    event NewMultiRewardsVaultStrategy(
        address indexed strategy,
        address indexed vault,
        address indexed multiRewardsAddress
    );

    constructor(address _management, address _sms) {
        management = _management;
        sms = _sms;
    }

    function newMultiRewardsVaultStrategy(
        address _asset,
        string memory _name,
        address _vault,
        address _multiRewardsAddress
    ) external returns (address) {
        IStrategyInterface newStrategy = IStrategyInterface(
            address(
                new MultiRewardsVaultStrategy(
                    address(_asset),
                    _name,
                    _vault,
                    _multiRewardsAddress
                )
            )
        );

        newStrategy.setPendingManagement(management);
        newStrategy.setPerformanceFeeRecipient(management);
        newStrategy.setEmergencyAdmin(sms);

        emit NewMultiRewardsVaultStrategy(
            address(newStrategy),
            _vault,
            _multiRewardsAddress
        );

        return address(newStrategy);
    }
}