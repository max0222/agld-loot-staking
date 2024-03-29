// SPDX-License-Identifier: GPL-3.0-or-later
pragma solidity ^0.8.10;

import "./lib/Math.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import "solmate/utils/SafeTransferLib.sol";
import {ERC20 as SolmateERC20} from "solmate/tokens/ERC20.sol";
import {ERC721 as SolmateERC721} from "solmate/tokens/ERC721.sol";


contract LootStaking is Ownable {
    using SafeTransferLib for SolmateERC20;

    /*///////////////////////////////////////////////////////////////
                            ERRORS
    //////////////////////////////////////////////////////////////*/

    error StartTimeInvalid();
    error StakingAlreadyStarted();
    error StakingNotActive();
    error StakingEnded();
    error EpochInvalid();
    error NoRewards();
    error WeightsInvalid();
    error NotBagOwner();
    error BagAlreadyStaked();

    /*///////////////////////////////////////////////////////////////
                             EVENTS
    //////////////////////////////////////////////////////////////*/

    event RewardsAdded(uint256 indexed _rewards);
    event StakingStarted(uint256 indexed _startTime);
    event WeightsSet(uint256 indexed _lootWeight, uint256 indexed _mLootWeight);
    event BagsStaked(address indexed _owner, uint256 indexed _numBags);
    event RewardsClaimed(address indexed _owner, uint256 indexed _amount);

    /*///////////////////////////////////////////////////////////////
                             CONSTANTS
    // //////////////////////////////////////////////////////////////*/
    SolmateERC721 public LOOT;
    SolmateERC721 public MLOOT;
    SolmateERC20 public AGLD;

    /*///////////////////////////////////////////////////////////////
                             STORAGE
    //////////////////////////////////////////////////////////////*/
    /// @notice When staking begins.
    uint256 public stakingStartTime;
    uint256 public immutable numEpochs;
    uint256 public immutable epochDuration;
    uint256 public rewardsAmount;

    /// @notice Loot reward share weight represented as basis points. Epochs are 1-indexed.
    mapping(uint256 => uint256) private lootWeightsByEpoch;
    /// @notice mLoot reward share weight represented as basis points. Epochs are 1-indexed.
    mapping(uint256 => uint256) private mLootWeightsByEpoch;

    /// @notice Epochs are 1-indexed.
    mapping(uint256 => mapping(uint256 => bool)) public stakedLootIdsByEpoch;
    mapping(uint256 => uint256[]) public epochsByLootId;
    mapping(uint256 => uint256) public numLootStakedByEpoch;
    mapping(uint256 => uint256) public numLootStakedById;
    mapping(address => uint256) public numLootStakedByAccount;

    mapping(uint256 => mapping(uint256 => bool)) public stakedMLootIdsByEpoch;
    mapping(uint256 => uint256[]) public epochsByMLootId;
    mapping(uint256 => uint256) public numMLootStakedByEpoch;
    mapping(uint256 => uint256) public numMLootStakedById;
    mapping(address => uint256) public numMLootStakedByAccount;

    mapping(address => uint256) public claimByAccount;

    /*///////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Initialize the staking contract with the num epochs, duration, and
    ///         initial weights for all epochs.
    /// @param _numEpochs The number of epochs in the staking period.
    /// @param _epochDuration The duration of each epoch in seconds.
    /// @param _lootWeight The initial weight for Loot bags in basis points.
    /// @param _mLootWeight The initial weight for mLoot bags in basis points.
    constructor(
        uint256 _numEpochs,
        uint256 _epochDuration,
        uint256 _lootWeight,
        uint256 _mLootWeight,
        address lootAddress,
        address mLootAddress,
        address agldAddress
    ) {
        LOOT = SolmateERC721(lootAddress);
        MLOOT = SolmateERC721(mLootAddress);
        AGLD = SolmateERC20(agldAddress);
        numEpochs = _numEpochs;
        epochDuration = _epochDuration;

        for (uint256 i = 1; i <= numEpochs;) {
            lootWeightsByEpoch[i] = _lootWeight;
            mLootWeightsByEpoch[i] = _mLootWeight;
            unchecked { ++i; }
        }
    }

    /*///////////////////////////////////////////////////////////////
                             ADMIN
    //////////////////////////////////////////////////////////////*/

    /// @notice Sets starting time for staking rewards. Must be at least 1 epoch
    ///         after the current time.
    /// @param _startTime The unix time to start staking rewards in seconds.
    function setStakingStartTime(
        uint256 _startTime
    ) external onlyOwner {
        if (rewardsAmount == 0) revert NoRewards();
        if (stakingStartTime != 0) revert StakingAlreadyStarted();
        if (_startTime < block.timestamp + epochDuration) revert StartTimeInvalid();
        stakingStartTime = _startTime;

        emit StakingStarted(_startTime);
    }

    /// @notice Set epoch weights. Can only set for an epoch in the future.
    /// @param _epoch The epoch to set weights for.
    /// @param _lootWeight The reward share weight for Loot bags in basis points.
    /// @param _mLootWeight The reward share weight for mLoot bags in basis points.
    function setWeightsForEpoch(
        uint256 _epoch,
        uint256 _lootWeight,
        uint256 _mLootWeight
    ) external onlyOwner {
        uint256 currentEpoch = getCurrentEpoch();
        if (_epoch <= currentEpoch || _epoch > numEpochs) revert EpochInvalid();
        if (_lootWeight + _mLootWeight != 1e4) revert WeightsInvalid();

        lootWeightsByEpoch[_epoch] = _lootWeight;
        mLootWeightsByEpoch[_epoch] = _mLootWeight;

        emit WeightsSet(_lootWeight, _mLootWeight);
    }

    /// @notice Increase the internal balance of rewards. This should be called
    ///         after sending tokens to this contract.
    /// @param _amount The amount of rewards to increase.
    function notifyRewardAmount(
        uint256 _amount
    ) external onlyOwner {
        if (stakingStartTime != 0) revert StakingAlreadyStarted();

        // Proper ERC-20 implementation ensures total supply capped at uint256 max.
        unchecked {
            rewardsAmount += _amount;
        }

        emit RewardsAdded(_amount);
    }

    /*///////////////////////////////////////////////////////////////
                             STAKING LOGIC
    //////////////////////////////////////////////////////////////*/

    /// @notice Stakes Loot bags for upcoming epoch.
    /// @param _ids Loot bags to stake.
    function signalLootStake(
        uint256[] calldata _ids
    ) external {
        _signalStake(_ids, LOOT, stakedLootIdsByEpoch, numLootStakedByEpoch, numLootStakedById, numLootStakedByAccount);
    }

    /// @notice Stakes mLoot bags for upcoming epoch.
    /// @param _ids mLoot bags to stake.
    function signalMLootStake(
        uint256[] calldata _ids
    ) external {
        _signalStake(_ids, MLOOT, stakedMLootIdsByEpoch, numMLootStakedByEpoch, numMLootStakedById, numMLootStakedByAccount);
    }

    /// @notice Stakes token ids of a specific collection for the immediate next
    ///         epoch.
    /// @param _ids NFT token IDs to stake.
    /// @param _nftToken NFT collection being staked.
    /// @param stakedNFTsByEpoch Mapping of staked NFT token IDs by epoch.
    /// @param numNFTsStakedByEpoch Mapping of number of staked NFT token IDs by epoch.
    function _signalStake(
        uint256[] calldata _ids,
        SolmateERC721 _nftToken,
        mapping(uint256 => mapping(uint256 => bool)) storage stakedNFTsByEpoch,
        mapping(uint256 => uint256) storage numNFTsStakedByEpoch,
        mapping(uint256 => uint256) storage numNFTsStakedById,
        mapping(address => uint256) storage numNFTsStakedByAccount
    ) internal {
        if (stakingStartTime == 0) revert StakingNotActive();
        uint256 currentEpoch = getCurrentEpoch();
        if (currentEpoch >= numEpochs) revert StakingEnded();

        uint256 signalEpoch = currentEpoch + 1;
        uint256 length = _ids.length;
        uint256 bagId;
        for (uint256 i = 0; i < length;) {
            bagId = _ids[i];
            if (_nftToken.ownerOf(bagId) != msg.sender) revert NotBagOwner();
            if (stakedNFTsByEpoch[signalEpoch][bagId]) revert BagAlreadyStaked();

            // Increment staked count for epoch.
            // Loot cannot overflow.
            // mLoot unlikely to reach overflow limit.
            unchecked {
                ++numNFTsStakedByEpoch[signalEpoch];
                ++numNFTsStakedById[bagId];
                ++numNFTsStakedByAccount[msg.sender];
            }

            // Mark NFT as staked for this epoch.
            stakedNFTsByEpoch[signalEpoch][bagId] = true;

            // Record epoch for this loot.
            epochsByLootId[bagId].push(signalEpoch);

            unchecked { ++i; }
        }

        emit BagsStaked(msg.sender, length);
    }

    /// @notice Claims all staking rewards for specific Loot bags.
    /// @param _ids Loot bags to claim rewards for.
    function claimLootRewards(
        uint256[] calldata _ids
    ) external {
        _claimRewards(_ids, LOOT, lootWeightsByEpoch, epochsByLootId, numLootStakedByEpoch);
    }

    /// @notice Claims all staking rewards for specific mLoot bags.
    /// @param _ids Loot bags to claim rewards for.
    function claimMLootRewards(
        uint256[] calldata _ids
    ) external {
        _claimRewards(_ids, MLOOT, mLootWeightsByEpoch, epochsByMLootId, numMLootStakedByEpoch);
    }

    /// @notice Claims the rewards for token IDs of a specific collection.
    /// @param _ids NFT token IDs to claim rewards for.
    function _claimRewards(
        uint256[] calldata _ids,
        SolmateERC721 nftToken,
        mapping(uint256 => uint256) storage nftWeights,
        mapping(uint256 => uint256[]) storage epochsByNFTId,
        mapping(uint256 => uint256) storage numNFTsStakedByEpoch
    ) internal {
        uint256 rewards;
        uint256 rewardPerEpoch = getTotalRewardPerEpoch();
        uint256 currentEpoch = getCurrentEpoch();

        uint256 length = _ids.length;
        uint256 bagId;
        uint256 epochsLength;
        uint256 epoch;
        uint256 j;
        for (uint256 i = 0; i < length;) {
            bagId = _ids[i];
            if (nftToken.ownerOf(bagId) != msg.sender) revert NotBagOwner();

            epochsLength = epochsByNFTId[bagId].length;
            for (j = 0; j < epochsLength;) {
                epoch = epochsByNFTId[bagId][j];
                if (epoch != currentEpoch) {
                    // Proper ERC-20 implementation ensures total supply capped at uint256 max.
                    unchecked {
                        rewards += Math.mulDiv(rewardPerEpoch, nftWeights[epoch], 10000) / numNFTsStakedByEpoch[epoch];
                    }
                }

                unchecked { ++j; }
            }

            // Clear epochs that the bag's rewards have been claimed for.
            if (epochsByNFTId[bagId][epochsLength - 1] == currentEpoch) {
                epochsByNFTId[bagId] = [currentEpoch];
            } else {
                delete epochsByNFTId[bagId];
            }
            unchecked { ++i; }
        }

        claimByAccount[msg.sender] += rewards;
        AGLD.safeTransfer(msg.sender, rewards);
        emit RewardsClaimed(msg.sender, rewards);
    }

    /*///////////////////////////////////////////////////////////////
                             GETTERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claims all staking rewards for Loot bags.
    /// @return currentEpoch The current epoch. 0 represents time before the first epoch.
    function getCurrentEpoch() public view returns (uint256 currentEpoch) {
        if (block.timestamp < stakingStartTime) return 0;
        currentEpoch = ((block.timestamp - stakingStartTime) / epochDuration) + 1;
    }

    /// @notice Gets the bag reward weights for an epoch.
    /// @param _epoch The epoch to get the weights for.
    /// @return lootWeight The weight for Loot bags in basis points.
    /// @return mLootWeight The weight for mLoot bags in basis points.
    function getWeightsForEpoch(
        uint256 _epoch
    ) public view returns (uint256 lootWeight, uint256 mLootWeight) {
        lootWeight = lootWeightsByEpoch[_epoch];
        mLootWeight = mLootWeightsByEpoch[_epoch];
    }

    /// @notice Gets the amount of rewards allotted per epoch.
    /// @return amount Amount of rewards per epoch.
    function getTotalRewardPerEpoch() public view returns (uint256 amount) {
        amount = rewardsAmount / numEpochs;
    }

    /// @notice Calculates the currently claimable rewards for a Loot bag.
    /// @dev Grab the epochs the bag was staked for and run calculation for each
    ///      epoch.
    /// @param _id The bag to calculate rewards for.
    /// @return rewards Claimable rewards for the bag.
    function getClaimableRewardsForLootBag(uint256 _id) external view returns (uint256 rewards) {
        rewards = _getClaimableRewardsForEpochs(lootWeightsByEpoch, epochsByLootId[_id], numLootStakedByEpoch);
    }

    /// @notice Calculates the currently claimable rewards for a Loot bag.
    /// @dev Grab the epochs the bag was staked for and run calculation for each
    ///      epoch.
    /// @param _id The bag to calculate rewards for.
    /// @return rewards Claimable rewards for the bag.
    function getClaimableRewardsForMLootBag(uint256 _id) external view returns (uint256 rewards) {
        rewards = _getClaimableRewardsForEpochs(mLootWeightsByEpoch, epochsByMLootId[_id], numMLootStakedByEpoch);
    }

    /// @notice Calculates the currently claimable rewards for a bag that was
    ///         staked in a list of epochs. Excludes the current epoch.
    /// @param _nftWeights The list of NFT reward weights.
    /// @param _epochs The epochs the bag was staked in.
    function _getClaimableRewardsForEpochs(
        mapping(uint256 => uint256) storage _nftWeights,
        uint256[] memory _epochs,
        mapping(uint256 => uint256) storage numNFTsStakedByEpoch
    ) internal view returns (uint256 rewards) {
        uint256 rewardPerEpoch = getTotalRewardPerEpoch();
        uint256 currentEpoch = getCurrentEpoch();
        uint256 epochsLength = _epochs.length;
        uint256 epoch;
        for (uint256 i = 0; i < epochsLength;) {
            epoch = _epochs[i];
            if (epoch != currentEpoch) {
                unchecked {
                    rewards += Math.mulDiv(rewardPerEpoch, _nftWeights[epoch], 10000) / numNFTsStakedByEpoch[epoch];
                }
            }

            unchecked { ++i; }
        }
    }
}
