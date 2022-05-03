pragma solidity ^0.8.13;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

struct StakingConfiguration {
    uint256 daysInPeriod;
    uint256 period;
    uint256 percentage;
    bool active;
}

struct AddressStakingInfo {
    uint256 stakingAmount;
    uint256 start;
    uint256 end;
    uint256 period;
    uint256 daysInPeriod;
    uint256 percentage;
    uint256 earned;
    uint256 lastClaimTimestamp;
    bool active;
}

contract GXBStaking is Ownable {
    using SafeERC20 for IERC20;

    // constants for timestamp calculation
    uint256 private constant HOURS_IN_DAY = 24;
    uint256 private constant MINUTES_IN_HOUR = 60;
    uint256 private constant SECONDS_IN_MINUTE = 60;
    uint256 public constant ERC20_Decimals = 18;

    // address of GBX ERC20 token
    address private immutable GBX_TOKEN;

    // staking addresses with it's configurations
    mapping(address => AddressStakingInfo) public stakeBalances;
    address[] private stakeAddresses;

    // possible staking configurations
    StakingConfiguration[] private stakingConfigurations;

    constructor(address gbxToken) {
        GBX_TOKEN = gbxToken;

        uint256 three_month_unix = 90 * HOURS_IN_DAY * MINUTES_IN_HOUR * SECONDS_IN_MINUTE; // 90 days = 3 month
        uint256 six_month_unix = 180 * HOURS_IN_DAY * MINUTES_IN_HOUR * SECONDS_IN_MINUTE; // 180 days = 6 month
        uint256 year_unix = 360 * HOURS_IN_DAY * MINUTES_IN_HOUR * SECONDS_IN_MINUTE; // 360 days = 12 month

        stakingConfigurations.push(StakingConfiguration(90, three_month_unix, 10, true)); // 3 month for 10%
        stakingConfigurations.push(StakingConfiguration(180, six_month_unix, 20, true)); // 6 month for 20%
        stakingConfigurations.push(StakingConfiguration(360, year_unix, 40, true)); // 12 month for 40%
    }

    /**
        Inserts or updates staking configuration by days period.
        If days period exists - updates percentages
        Otherwise creates new staking configuration
     */
    function updateStakingConfiguration(uint256 daysInPeriod, uint256 percentage) public onlyOwner {
        uint256 period = daysInPeriod * HOURS_IN_DAY * MINUTES_IN_HOUR * SECONDS_IN_MINUTE;

        for(uint i = 0; i < stakingConfigurations.length; i++) {
            if(stakingConfigurations[i].daysInPeriod == daysInPeriod) {
                stakingConfigurations[i].percentage = percentage;
                return;
            }
        }

        stakingConfigurations.push(StakingConfiguration(daysInPeriod, period, percentage, true));
    }

    /**
        Disables active staking configuration
     */
    function disableStakingConfiguration(uint256 stakingOption) public onlyOwner {
        require(stakingConfigurations[stakingOption].active, "GBXStaking: wrong staking option specified.");
        stakingConfigurations[stakingOption].active = false;
    }

    /**
        Stakes specified amount for sender wallet with selected staking option
        Requires:
        - unique address to stake
        - amount for staking more than zero
        - existing stakingOption

        Specified amount sents to contract address
     */
    function stake(uint256 amount, uint256 stakingOption) public {
        require(!stakeBalances[msg.sender].active, "GBXStaking: an address already participating in staking.");
        require(amount > 0, "GBXStaking: specified staking amount should be more than 0.");
        require(stakingConfigurations.length - 1 >= stakingOption, "GBXStaking: wrong staking option specified.");
        require(stakingConfigurations[stakingOption].active, "GBXStaking: staking option is not active.");

        IERC20(GBX_TOKEN).safeTransferFrom(msg.sender, address(this), amount);
        
        StakingConfiguration memory selectedStakingOption = stakingConfigurations[stakingOption];
        uint256 start = getCurrentTime();
        uint256 end = start + selectedStakingOption.period;

        stakeBalances[msg.sender] = AddressStakingInfo(amount, start, end, selectedStakingOption.period, selectedStakingOption.daysInPeriod, selectedStakingOption.percentage, 0, start, true);
        stakeAddresses.push(msg.sender);
    }

    /**
        Unstakes specified amount for sender wallet 
        Requires:
        - address that stakes anything
        - staking period ends

        Deletes wallet from stakers addresses and transfers tokens from contract address to user wallet address
     */
    function unstake() public {
        require(stakeBalances[msg.sender].active, "GBXStaking: an address not participating in staking.");
        require(getCurrentTime() >= stakeBalances[msg.sender].end, "GBXStaking: staking period for specified address not ended.");

        IERC20(GBX_TOKEN).safeTransfer(msg.sender, stakeBalances[msg.sender].stakingAmount);
        delete stakeBalances[msg.sender];
    }

    /**
        When staking period ends it's possible to restake staked amount with specified staking configuration
        Requires:
        - address that stakes anything
        - staking period ends
        - existing staking configuration

        Overrides staking configurations for specific wallet address.
        Tokens can't be unstaked if restake started.
     */
    function restake(uint256 stakingOption) public {
        require(stakeBalances[msg.sender].active, "GBXStaking: an address not participating in staking.");
        require(getCurrentTime() >= stakeBalances[msg.sender].end, "GBXStaking: staking period for specified address not ended.");
        require(stakingConfigurations.length - 1 >= stakingOption, "GBXStaking: wrong staking option specified.");
        require(stakingConfigurations[stakingOption].active, "GBXStaking: staking option is not active.");

        StakingConfiguration memory selectedStakingOption = stakingConfigurations[stakingOption];
        uint256 start = getCurrentTime();
        uint256 end = start + selectedStakingOption.period;

        stakeBalances[msg.sender].start = start;
        stakeBalances[msg.sender].end = end;
        stakeBalances[msg.sender].period = selectedStakingOption.period;
        stakeBalances[msg.sender].daysInPeriod = selectedStakingOption.daysInPeriod;
        stakeBalances[msg.sender].percentage = selectedStakingOption.percentage;
        stakeBalances[msg.sender].lastClaimTimestamp = start;
        stakeBalances[msg.sender].earned = 0;
    }

    /**
        Claims reward for sender wallet if available
        Requires:
        - address that stakes anything
        - staking period not yet ended
        - reward amount more then zero
     */
    function claimReward() public {
        require(stakeBalances[msg.sender].active, "GBXStaking: an address not participating in staking.");
        require(getCurrentTime() < stakeBalances[msg.sender].end, "GBXStaking: staking period ended.");
     
        uint256 rewardAmount = calculateReward();
        require(rewardAmount > 0, "GBXStaking: rewards are not available at the moment.");

        IERC20(GBX_TOKEN).safeTransfer(msg.sender, rewardAmount);
        stakeBalances[msg.sender].earned += rewardAmount;
        stakeBalances[msg.sender].lastClaimTimestamp = getCurrentTime();
    }

    /**
        Gets list of available staking configurations
     */
    function getStakingConfigurations() public view returns(StakingConfiguration[] memory){
        return stakingConfigurations;
    }

    /**
        Calculates available rewards for specific address
        Requires:
        - address that stakes anything
        - staking period not yet ended
     */
    function calculateReward() public view returns(uint256) {
        require(stakeBalances[msg.sender].active, "GBXStaking: an address not participating in staking.");
        require(getCurrentTime() < stakeBalances[msg.sender].end, "GBXStaking: staking period ended.");

        uint256 timeFromLastClaim = getCurrentTime() - stakeBalances[msg.sender].lastClaimTimestamp;
        uint256 daysAfterLastClaim = timeFromLastClaim / (HOURS_IN_DAY * MINUTES_IN_HOUR * SECONDS_IN_MINUTE);

        uint256 stakedPerWallet = stakeBalances[msg.sender].stakingAmount;
        uint256 stakingDays = stakeBalances[msg.sender].daysInPeriod;
        uint256 percentage = stakeBalances[msg.sender].percentage;

        return daysAfterLastClaim * getDailyEarnings(stakedPerWallet, stakingDays, percentage);
    }

    /**
        Returns amount of addresses in staking
     */
    function getStakersLength() view public returns(uint256) {
        return stakeAddresses.length;
    }

    /**
        Retuns amount of tokens in staking pool
     */
    function stakedAmount() view public returns(uint256) {
        uint256 staked = 0;

        for(uint256 i = 0; i < stakeAddresses.length; i++) {
            address currentAddress = stakeAddresses[i];
            staked += stakeBalances[currentAddress].stakingAmount;
        }

        return staked;
    }

    /**
        Estimates how much tokens can be taken as a reward for specific user wallet address
        Requires:
        - address that stakes anything
        - staking period not yet ended
     */
    function estimatedDailyEarnings(uint256 stakedPerWallet, uint256 stakingOption) view public returns(uint256) {
        StakingConfiguration memory configuration = stakingConfigurations[stakingOption];

        return getDailyEarnings(stakedPerWallet, configuration.daysInPeriod, configuration.percentage);
    }

    function getDailyEarnings(uint256 stakedPerWallet, uint256 stakingDays, uint256 percentage) pure internal returns(uint256) {
        uint256 totalReceiveForPeriod = (stakedPerWallet * percentage) / 100;
        return totalReceiveForPeriod / stakingDays;
    }

    function getCurrentTime()
        internal
        virtual
        view
        returns(uint256) {
        return block.timestamp;
    }
}