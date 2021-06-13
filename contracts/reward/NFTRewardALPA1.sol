pragma solidity ^0.5.0;

import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC721/ERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
// exohood
import "../library/SafeERC20.sol";
import "../interface/IPool.sol";
import "../interface/IERC20.sol";
import "../interface/EXOFactory.sol";
import "../interface/EXOToken.sol";

contract NFTRewardALPA1 is IPool {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    // --- Data ---
    bool private initialized; // Flag of initialize data
    
    IERC20 public _rewardToken = IERC20(0x0);
    exoFactory public _exoFactory = exoFactory(0x0);
    exoToken public _exoToken = exoToken(0x0);

    address public _rewardPool = address(0x0);

    uint256 public _startTime =  now + 365 days;// 1607086800
    uint256 public DURATION = 28 days;
    uint256 public _rewardRate = 0;
    bool public _hasStart = false;
    uint256 public _periodFinish = 0;

    uint256 public _initReward = 0;
    uint256 public _lastUpdateTime;
    uint256 public _rewardPerTokenStored;
    uint256 public _poolRewardRate = 1000;
    uint256 public _baseRate = 10000;
    uint256 public _punishTime = 3 days;

    mapping(address => uint256) public _userRewardPerTokenPaid;
    mapping(address => uint256) public _rewards;
    mapping(address => uint256) public _lastStakedTime;
    
    uint256 public _fixRateBase = 100000;
    
    uint256 public _totalWeight;
    mapping(address => uint256) public _weightBalances;

    mapping(address => uint256[]) public _playerGego;
    mapping(uint256 => uint256) public _gegoMapIndex;

    address public _governance;

    event NotifyReward(uint256 reward);
    event StakedEXO(address indexed user, uint256 amount);
    event WithdrawnGego(address indexed user, uint256 amount);
    event RewardPaid(address indexed user, uint256 reward);
    event NFTReceived(address operator, address from, uint256 tokenId, bytes data);
    event SetStartTime(uint256 startTime);
    event FinishReward(uint256 reward);
    event StartReward(uint256 reward);
    event GovernanceTransferred(address indexed previousOwner, address indexed newOwner);

    modifier updateReward(address account) {
        _rewardPerTokenStored = rewardPerToken();
        _lastUpdateTime = lastTimeRewardApplicable();
        if (account != address(0)) {
            _rewards[account] = earned(account);
            _userRewardPerTokenPaid[account] = _rewardPerTokenStored;
        }
        _;
    }

    modifier onlyGovernance {
        require(msg.sender == _governance, "not governance");
        _;
    }

    constructor() public {
        _governance = tx.origin;
    }

    // --- Init ---
    function initialize(
        address rewardPool, 
        address rewardToken, 
        address exoToken, 
        address exoFactory
    ) public {
        require(!initialized, "initialize: Already initialized!");
        _governance = msg.sender;
        _rewardPool = rewardPool;
        _rewardToken = IERC20(rewardToken);
        _exoToken = exoToken(exoToken);
        _exoFactory = exoFactory(exoFactory);

        _startTime =  now + 365 days;
        DURATION = 28 days;
        _poolRewardRate = 1000;
        _baseRate = 10000;
        _punishTime = 3 days;
        _fixRateBase = 100000;

        initialized = true;
    }

    function totalSupply()  public view returns (uint256) {
        return _totalWeight;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _weightBalances[account];
    }

    /* Fee collection for any other token */
    function seize(IERC20 token, uint256 amount) external {
        require(token != _rewardToken, "reward");
        token.safeTransfer(_governance, amount);
    }
    
    /* Fee collection for any other token */
    function seizeErc721(IERC721 token, uint256 tokenId) external {
        require(token != _exoToken, "reward");
        token.safeTransferFrom(address(this), _governance, tokenId);
    }

    function rewardPerToken() public view returns (uint256) {
        if (totalSupply() == 0) {
            return _rewardPerTokenStored;
        }
        return
            _rewardPerTokenStored.add(
                lastTimeRewardApplicable()
                    .sub(_lastUpdateTime)
                    .mul(_rewardRate)
                    .mul(1e18)
                    .div(totalSupply())
            );
    }

    function earned(address account) public view returns (uint256) {
        return
            balanceOf(account)
                .mul(rewardPerToken().sub(_userRewardPerTokenPaid[account]))
                .div(1e18)
                .add(_rewards[account]);
    }

    
    //the grade is a number between 1-6
    //the quality is a number between 1-10000
    /*
    1   quality	1.1+ 0.1*quality/5000
    2	quality	1.2+ 0.1*(quality-5000)/3000
    3	quality	1.3+ 0.1*(quality-8000/1000
    4	quality	1.4+ 0.2*(quality-9000)/800
    5	quality	1.6+ 0.2*(quality-9800)/180
    6	quality	1.8+ 0.2*(quality-9980)/20
    */

    function getFixRate(uint256 grade,uint256 quality) public pure returns (uint256){

        require(grade > 0 && grade <7, "the exo not token");

        uint256 unfold = 0;
        if( grade == 1 ){
            unfold = quality*10000/5000;
            return unfold.add(110000);
        }else if( grade == 2){
            unfold = quality.sub(5000)*10000/3000;
            return unfold.add(120000);
        }else if( grade == 3){
            unfold = quality.sub(8000)*10000/1000;
           return unfold.add(130000);
        }else if( grade == 4){
            unfold = quality.sub(9000)*20000/800;
           return unfold.add(140000);
        }else if( grade == 5){
            unfold = quality.sub(9800)*20000/180;
            return unfold.add(160000);
        }else{
            unfold = quality.sub(9980)*20000/20;
            return unfold.add(180000);
        }
    }

    function getStakeInfo( uint256 gegoId ) public view returns ( uint256 stakeRate, uint256 amount){

        uint256 grade;
        uint256 quality; 
        (grade, quality, amount, , , , ) = _exoFactory.exo(exoId);
        require(amount > 0,"the exo not token");
        stakeRate = getFixRate(grade,quality);
    }

    // stake exo 
    function stakeexo(uint256 exoId)
        public
        updateReward(msg.sender)
    {
        require(block.timestamp >= _startTime, "not start");

        uint256[] storage exoIds = _playerexo[msg.sender];
        if (exoIds.length == 0) {
            exoIds.push(0);    
            _exoMapIndex[0] = 0;
        }
        exoIds.push(exoId);
        _exoMapIndex[exoId] = exoIds.length - 1;

        uint256 stakeRate;
        uint256 ercAmount;
        (stakeRate, ercAmount) = getStakeInfo(exoId);
        
        if(ercAmount > 0){
            uint256 stakeWeight = stakeRate.mul(ercAmount).div(_fixRateBase);
            _weightBalances[msg.sender] = _weightBalances[msg.sender].add(stakeWeight);
            _totalWeight = _totalWeight.add(stakeWeight);
        }

        _exoToken.safeTransferFrom(msg.sender, address(this), gegoId);
        
        _lastStakedTime[msg.sender] = now;

        emit Stakedexo(msg.sender, exoId);
        
    }
    
    function onERC721Received(address operator, address from, uint256 tokenId, bytes memory data) public returns (bytes4) {
        if(_hasStart == false) {
            return 0;
        }

        emit NFTReceived(operator, from, tokenId, data);
        return bytes4(keccak256("onERC721Received(address,address,uint256,bytes)"));
    }

    function withdrawEXO(uint256 exoId)
        public
        updateReward(msg.sender)
    {
        require(EXOId > 0, "the exoId error");
        
        uint256[] memory gegoIds = _playerexo[msg.sender];
        uint256 exoIndex = _exoMapIndex[exoId];
        
        require(exoIds[exoIndex] == exoId, "not exoId owner");

        uint256 exoArrayLength = exoIds.length-1;
        uint256 tailId = exoIds[exoArrayLength];

        _playerexo[msg.sender][exoIndex] = tailId;
        _playerexo[msg.sender][exoArrayLength] = 0;
        _playerexo[msg.sender].length--;
        _exoMapIndex[tailId] = exoIndex;
        _exoMapIndex[exoId] = 0;

        uint256 stakeRate;
        uint256 ercAmount;
        (stakeRate, ercAmount) = getStakeInfo(exoId);
        uint256 stakeWeight = stakeRate.mul(ercAmount).div(_fixRateBase);
        _weightBalances[msg.sender] = _weightBalances[msg.sender].sub(stakeWeight);
        _totalWeight = _totalWeight.sub(stakeWeight);
        
        _exoToken.safeTransferFrom(address(this), msg.sender, exoId);

        emit WithdrawnEXO(msg.sender, exoId);
    }

    function withdraw()
        public
    {
        uint256[] memory exoId = _playerexo[msg.sender];
        for (uint8 index = 1; index < exoId.length; index++) {
            if (exoId[index] > 0) {
                withdrawexo(exoId[index]);
            }
        }
    }

    function getPlayerIds( address account ) public view returns( uint256[] memory exoId )
    {
        exoId = _playerexo[account];
    }

    function exit() external {
        withdraw();
        getReward();
    }

    function getReward() public updateReward(msg.sender) {
        uint256 reward = earned(msg.sender);
        if (reward > 0) {
            uint256 poolReward = 0;
            uint256 leftReward = reward;
            //withdraw time check
            if(now  < (_lastStakedTime[msg.sender] + _punishTime) ){
                poolReward = leftReward.mul(_poolRewardRate).div(_baseRate);
            }

            if(poolReward>0){
                _rewardToken.safeTransfer(_rewardPool, poolReward);
                leftReward = leftReward.sub(poolReward);
            }

            _rewards[msg.sender] = 0;
            _rewardToken.safeTransfer(msg.sender, leftReward);
            emit RewardPaid(msg.sender, reward);
        }
    }

    function lastTimeRewardApplicable() public view returns (uint256) {
        return Math.min(block.timestamp, _periodFinish);
    }
    
    // set fix time to start reward
    function startNFTReward(uint256 startTime)
        external
        onlyGovernance
        updateReward(address(0))
    {
        require(_initReward > 0, "first notifyReward");
        require(_hasStart == false, "has started");
        _hasStart = true;
        
        _startTime = startTime;
        _rewardRate = _initReward.div(DURATION); 

        _lastUpdateTime = _startTime;
        _periodFinish = _startTime.add(DURATION);

        emit SetStartTime(_initReward);
    }
    
    //for notify reward
    function notifyRewardAmount(uint256 reward)
        external
        onlyGovernance
        updateReward(address(0))
    {
        uint256 balanceBefore = _rewardToken.balanceOf(address(this));
        _rewardToken.safeTransferFrom(msg.sender, address(this), reward);
        uint256 balanceEnd = _rewardToken.balanceOf(address(this));

        _initReward = _initReward.add(balanceEnd.sub(balanceBefore));

        emit NotifyReward(_initReward);
    }

    function setGovernance(address governance)  public  onlyGovernance
    {
        require(governance != address(0), "new governance the zero address");
        emit GovernanceTransferred(_governance, governance);
        _governance = governance;
    }

}
