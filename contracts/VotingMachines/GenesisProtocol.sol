pragma solidity ^0.4.18;

import "../controller/Reputation.sol";
import "./IntVoteInterface.sol";
import "../universalSchemes/UniversalScheme.sol";
import "./GenesisProtocolFormulasInterface.sol";


/**
 * @title A governance contract -an organization's voting machine scheme.
 */
contract GenesisProtocol is IntVoteInterface,UniversalScheme,GenesisProtocolFormulasInterface {
    using SafeMath for uint;

    enum ProposalState { Closed, Executed, PreBoosted,Boosted,QuietEndingPeriod }

    struct Parameters {
        uint preBoostedVoteRequiredPercentage; // the absolute vote percentages bar.
        uint preBoostedVotePeriodLimit; //the time limit for a proposal to be in an absolute voting mode.
        uint boostedVotePeriodLimit; //the time limit for a proposal to be in an relative voting mode.
        uint thresholdConstA;
        uint thresholdConstB;
        GenesisProtocolFormulasInterface governanceFormulasInterface;
        uint minimumStakingFee;
        uint quietEndingPeriod;
        uint proposingRepRewardConstA;
        uint proposingRepRewardConstB;
        uint stakerFeeRatioForVoters; // a value between 0-100
        uint votersReputationLossRatio;
        uint votersGainRepRatioFromLostRep; // a value between 0-100
    }
    struct Voter {
        uint vote; // 0 - 'abstain'
        uint reputation; // amount of voter's reputation
        bool preBoosted;
    }

    struct Staker {
        uint vote; // 0 - 'abstain'
        uint amount; // amount of voter's reputation
    }

    struct Proposal {
        address avatar; // the organization's avatar the proposal is target to.
        uint numOfChoices;
        ExecutableInterface executable; // will be executed if the proposal will pass
        uint totalVotes;
        uint totalStakes;
        uint votersStakes;
        uint lostReputation;
        uint submittedTime;
        uint boostedPhaseTime; //the time the proposal shift to relative mode.
        ProposalState state;
        uint winningVote; //the winning vote.
        address proposer;
        uint boostedVotePeriodLimit;
        mapping(uint=>uint) votes;
        mapping(address=>Voter) voters;
        mapping(uint=>uint) stakes;
        mapping(address=>Staker) stakers;
    }

    event NewProposal(bytes32 indexed _proposalId, uint _numOfChoices, address _proposer, bytes32 _paramsHash);
    event ExecuteProposal(bytes32 indexed _proposalId, uint _decision);
    event VoteProposal(bytes32 indexed _proposalId, address indexed _voter, uint _vote, uint _reputation);
    event Stake(bytes32 indexed _proposalId, address indexed _voter,uint _vote,uint _amount);
    event Redeem(bytes32 indexed _proposalId, address indexed _beneficiary,uint _amount);
    event RedeemReputation(bytes32 indexed _proposalId, address indexed _beneficiary,int _amount);

    mapping(bytes32=>Parameters) public parameters;  // A mapping from hashes to parameters
    mapping(bytes32=>Proposal) public proposals; // Mapping from the ID of the proposal to the proposal itself.

    uint constant MAX_NUM_OF_CHOICES = 10;
    uint proposalsCnt; // Total amount of proposals
    mapping(address=>uint) public orgBoostedProposalsCnt;
    StandardToken public stakingToken;

    /**
     * @dev Constructor
     */
    function GenesisProtocol(StandardToken _stakingToken)
    public
    {
        stakingToken = _stakingToken;
    }

  /**
   * @dev Check that the proposal is votable (open and not executed yet)
   */
    modifier votable(bytes32 _proposalId) {
        require(isVotable(_proposalId));
        _;
    }

    /**
     * @dev hash the parameters, save them if necessary, and return the hash value
     * @param _params a parameters array
     *    _params[0] - _preBoostedVoteRequiredPercentage,
     *    _params[1] - _preBoostedVotePeriodLimit, //the time limit for a proposal to be in an absolute voting mode.
     *    _params[2] -_boostedVotePeriodLimit, //the time limit for a proposal to be in an relative voting mode.
     *    _params[3] -_thresholdConstA,
     *    _params[4] -_thresholdConstB,
     *    _params[5] -_minimumStakingFee,
     *    _params[6] -_quietEndingPeriod,
     *    _params[7] -_proposingRepRewardConstA,
     *    _params[8] -_proposingRepRewardConstB,
     *    _params[9] -_stakerFeeRatioForVoters,
     *    _params[10] -_votersReputationLossRatio,
     *    _params[11] -_votersGainRepRatioFromLostRep
     * @param _governanceFormulasInterface override the default formulas.
    */
    function setParameters(

        uint[12] _params, //use array here due to stack too deep issue.
        GenesisProtocolFormulasInterface _governanceFormulasInterface
        )
    public
    returns(bytes32)
    {
        require(_params[0] <= 100 && _params[0] > 0);
        require(_params[8] > 0); //_proposingRepRewardConstB cannot be zero.
        bytes32 hashedParameters = getParametersHash(
            _params,
            _governanceFormulasInterface
            );
        parameters[hashedParameters] = Parameters({
            preBoostedVoteRequiredPercentage: _params[0],
            preBoostedVotePeriodLimit: _params[1],
            boostedVotePeriodLimit: _params[2],
            thresholdConstA:_params[3],
            thresholdConstB:_params[4],
            minimumStakingFee: _params[5],
            quietEndingPeriod: _params[6],
            proposingRepRewardConstA: _params[7],
            proposingRepRewardConstB:_params[8],
            stakerFeeRatioForVoters:_params[9],
            votersReputationLossRatio:_params[10],
            votersGainRepRatioFromLostRep:_params[11],
            governanceFormulasInterface:_governanceFormulasInterface

        });
        return hashedParameters;
    }

  /**
   * @dev hashParameters returns a hash of the given parameters
   */
    function getParametersHash(
        uint[12] _params, //use array here due to stack too deep issue.
        GenesisProtocolFormulasInterface _governanceFormulasInterface)
        public
        pure
        returns(bytes32)
        {
        return keccak256(
            _params[0],
            _params[1],
            _params[2],
            _params[3],
            _params[4],
            _params[5],
            _params[6],
            _params[7],
            _params[8],
            _params[9],
            _params[10],
            _params[11],
            _governanceFormulasInterface);
    }

    /**
     * @dev register a new proposal with the given parameters. Every proposal has a unique ID which is being
     * generated by calculating keccak256 of a incremented counter.
     * @param _numOfChoices number of voting choices
     * @param _paramsHash defined the parameters of the voting machine used for this proposal
     * @param _avatar an address to be sent as the payload to the _executable contract.
     * @param _executable This contract will be executed when vote is over.
     * @param _proposer address
     */
    function propose(uint _numOfChoices, bytes32 _paramsHash, address _avatar, ExecutableInterface _executable,address _proposer) public returns(bytes32) {
          // Check valid params and number of choices:
        require(_numOfChoices > 0 && _numOfChoices <= MAX_NUM_OF_CHOICES);
        require(ExecutableInterface(_executable) != address(0));
        require(parameters[_paramsHash].preBoostedVoteRequiredPercentage > 0);
          // Generate a unique ID:
        bytes32 proposalId = keccak256(this, proposalsCnt);
        proposalsCnt++;
          // Open proposal:
        Proposal memory proposal;
        proposal.numOfChoices = _numOfChoices;
        proposal.avatar = _avatar;
        proposal.executable = _executable;
        proposal.state = ProposalState.PreBoosted;
        // solium-disable-next-line security/no-block-members
        proposal.submittedTime = now;
        proposal.boostedVotePeriodLimit = parameters[_paramsHash].boostedVotePeriodLimit;
        proposal.proposer = _proposer;
        proposals[proposalId] = proposal;
        NewProposal(proposalId, _numOfChoices, msg.sender, _paramsHash);
        return proposalId;
    }

  /**
   * @dev Cancel a proposal, only the owner can call this function and only if allowOwner flag is true.
   * @param _proposalId the proposal ID
   */
    function cancelProposal(bytes32 _proposalId) public onlyProposalOwner(_proposalId) votable(_proposalId) returns(bool) {
        //This is not allowed.
        return false;
    }

    /**
     * @dev staking function
     * @param _proposalId id of the proposal
     * @param _vote a value between 0 to and the proposal number of choices.
     * @param _amount the betting amount
     * @return bool true - the proposal has been executed
     *              false - otherwise.
     */
    function stake(bytes32 _proposalId, uint _vote, uint _amount) public returns(bool) {
        if (execute(_proposalId)) {
            return true;
        }
        if (proposals[_proposalId].state != ProposalState.PreBoosted) {
            return false;
        }
        Proposal storage proposal = proposals[_proposalId];
        uint amount = _amount;
        // Check valid vote:
        require(_vote < proposal.numOfChoices);

        bytes32 paramsHash = getParametersFromController(Avatar(proposals[_proposalId].avatar));
        Parameters memory params = parameters[paramsHash];
        assert(amount > params.minimumStakingFee);
        stakingToken.transferFrom(msg.sender, address(this), amount);

        proposal.stakers[msg.sender] = Staker({
            amount: amount,
            vote: _vote
        });
        proposal.votersStakes += (params.stakerFeeRatioForVoters * amount)/100;
        proposal.stakes[_vote] = amount.add(proposal.stakes[_vote]);
        amount = ((100-params.stakerFeeRatioForVoters)*amount)/100;
        proposal.totalStakes = amount.add(proposal.totalStakes);
      // Event:
        Stake(_proposalId, msg.sender, _vote, _amount);
      // execute the proposal if this vote was decisive:
        return execute(_proposalId);
    }

  /**
   * @dev voting function
   * @param _proposalId id of the proposal
   * @param _vote a value between 0 to and the proposal number of choices.
   * @return bool true - the proposal has been executed
   *              false - otherwise.
   */
    function vote(bytes32 _proposalId, uint _vote) public votable(_proposalId) returns(bool) {
        return internalVote(_proposalId, msg.sender, _vote, 0);
    }

  /**
   * @dev voting function with owner functionality (can vote on behalf of someone else)
   * @param _proposalId id of the proposal
   * @return bool true - the proposal has been executed
   *              false - otherwise.
   */
    function ownerVote(bytes32 _proposalId, uint , address ) public onlyProposalOwner(_proposalId) votable(_proposalId) returns(bool) {
      //This is not allowed.
        return false;
    }

    function voteWithSpecifiedAmounts(bytes32 _proposalId,uint _vote,uint _rep,uint) public votable(_proposalId) returns(bool) {
        return internalVote(_proposalId,msg.sender,_vote,_rep);
    }

  /**
   * @dev Cancel the vote of the msg.sender: subtract the reputation amount from the votes
   * and delete the voter from the proposal struct
   * @param _proposalId id of the proposal
   */
    function cancelVote(bytes32 _proposalId) public votable(_proposalId) {
       //this is not allowed
        return;
    }

  /**
    * @dev execute check if the proposal has been decided, and if so, execute the proposal
    * @param _proposalId the id of the proposal
    * @return bool true - the proposal has been executed
    *              false - otherwise.
   */
    function execute(bytes32 _proposalId) public votable(_proposalId) returns(bool) {
        bytes32 paramsHash = getParametersFromController(Avatar(proposals[_proposalId].avatar));
        Parameters memory params = parameters[paramsHash];
        Proposal storage proposal = proposals[_proposalId];
        Proposal memory tmpProposal;
        uint executionBar = Avatar(proposal.avatar).nativeReputation().totalSupply() * params.preBoostedVoteRequiredPercentage/100;

        if (proposal.state == ProposalState.PreBoosted) {
            // solium-disable-next-line security/no-block-members
            if ((now - proposal.submittedTime) >= params.preBoostedVotePeriodLimit) {
                tmpProposal = proposal;
                ExecuteProposal(_proposalId, 0);
                (tmpProposal.executable).execute(_proposalId, tmpProposal.avatar, int(0));
                proposals[_proposalId].state = ProposalState.Closed;
                proposal.winningVote = 0;
                return true;
             }
        // Check if someone crossed the absolute vote execution bar.
            if (proposal.votes[proposal.winningVote] > executionBar) {
                tmpProposal = proposal;
                ExecuteProposal(_proposalId, proposal.winningVote);
                (tmpProposal.executable).execute(_proposalId, tmpProposal.avatar, int(proposal.winningVote));
                proposals[_proposalId].state = ProposalState.Executed;
                return true;
               }
           //check if the proposal crossed its absolutePhaseScoreLimit or preBoostedVotePeriodLimit
            if ( shouldBoost(_proposalId)) {
                //change proposal mode to boosted mode.
                proposal.state = ProposalState.Boosted;
                // solium-disable-next-line security/no-block-members
                proposal.boostedPhaseTime = now;
                orgBoostedProposalsCnt[proposal.avatar]++;
              }
           }
        if ((proposal.state == ProposalState.Boosted) ||
            (proposal.state == ProposalState.QuietEndingPeriod)) {
            // solium-disable-next-line security/no-block-members
            if ((now - proposal.boostedPhaseTime) >= proposal.boostedVotePeriodLimit) {
                tmpProposal = proposal;
                ExecuteProposal(_proposalId, proposal.winningVote);
                (tmpProposal.executable).execute(_proposalId, tmpProposal.avatar, int(proposal.winningVote));
                proposals[_proposalId].state = ProposalState.Executed;
                orgBoostedProposalsCnt[tmpProposal.avatar]--;
                return true;
             }

         // Check if someone crossed the absolute vote execution bar.
            if (proposal.votes[proposal.winningVote] > executionBar) {
                tmpProposal = proposal;
                ExecuteProposal(_proposalId, proposal.winningVote);
                (tmpProposal.executable).execute(_proposalId, tmpProposal.avatar, int(proposal.winningVote));
                proposal.state = ProposalState.Executed;
                return true;
            }
       }
        return false;
    }

    /**
     * @dev redeem a reward for a successful stake, vote or proposing.
     * The function use a beneficiary address as a parameter (and not msg.sender) to enable
     * users to redeem on behalf of someone else.
     * @param _proposalId the ID of the proposal
     * @param _beneficiary - the beneficiary address
     * @return bool true or false.
     */
    function redeem(bytes32 _proposalId,address _beneficiary) public returns(bool) {
        Proposal storage proposal = proposals[_proposalId];
        require((proposal.state == ProposalState.Executed) || (proposal.state == ProposalState.Closed));
        uint amount;
        int reputation;
        if ((proposal.stakers[_beneficiary].amount>0) &&
             (proposal.stakers[_beneficiary].vote == proposals[_proposalId].winningVote)) {
            //as staker
            amount = redeemAmount(_proposalId,_beneficiary);
            reputation = redeemStakerRepAmount(_proposalId,_beneficiary);
            proposals[_proposalId].stakers[_beneficiary].amount = 0;
        }
        if ((proposal.numOfChoices == 2) && (proposal.voters[_beneficiary].reputation != 0 )) {
            //as voter
            amount += redeemVoterAmount(_proposalId,_beneficiary);
            reputation += redeemVoterReputation(_proposalId,_beneficiary);
            proposal.voters[_beneficiary].reputation = 0;
        }

        if ((proposal.numOfChoices == 2)&&(proposal.proposer == _beneficiary)&&(proposal.winningVote == 1)) {
            //as proposer
            reputation += redeemProposerReputation(_proposalId);
            proposal.proposer = 0;

        }
        if (amount != 0) {
            stakingToken.transfer(_beneficiary, amount);
            Redeem(_proposalId,_beneficiary,amount);
        }
        if (reputation != 0 ) {
            ControllerInterface(Avatar(proposal.avatar).owner()).mintReputation(reputation,_beneficiary,proposal.avatar);
            RedeemReputation(_proposalId,_beneficiary,reputation);
        }
        return true;
    }

    /**
     * @dev shouldBoost check if a proposal should be shifted to boosted phase.
     * @param _proposalId the ID of the proposal
     * @return bool true or false.
     */
    function shouldBoost(bytes32 _proposalId) public view returns(bool) {
        address avatar = proposals[_proposalId].avatar;
        bytes32 paramsHash = getParametersFromController(Avatar(avatar));
        Parameters memory params = parameters[paramsHash];
        if (params.governanceFormulasInterface == GenesisProtocolFormulasInterface(0)) {
            return (_score(_proposalId,Avatar(avatar).nativeReputation().totalSupply()) >= threshold(avatar));
        } else {
            return (params.governanceFormulasInterface).shouldBoost(_proposalId);
        }
    }

    /**
     * @dev score return the proposal score
     * @param _proposalId the ID of the proposal
     * @return uint proposal score.
     */
    function score(bytes32 _proposalId) public view returns(int) {
        bytes32 paramsHash = getParametersFromController(Avatar(proposals[_proposalId].avatar));
        Parameters memory params = parameters[paramsHash];
        if (params.governanceFormulasInterface == GenesisProtocolFormulasInterface(0)) {
            return _score(_proposalId, Avatar(proposals[_proposalId].avatar).nativeReputation().totalSupply());
        } else {
            return (params.governanceFormulasInterface).score(_proposalId);
        }
    }

    /**
     * @dev threshold return the organization's score threshold which required by
     * a proposal to shift to boosted state.
     * This threshold is dynamically set and it depend on the number of boosted proposal.
     * @param _avatar the organization avatar
     * @return int thresholdConstA.
     */
    function threshold(address _avatar) public view returns(int) {
        uint e = 2;
        bytes32 paramsHash = getParametersFromController(Avatar(_avatar));
        Parameters memory params = parameters[paramsHash];
        if (params.governanceFormulasInterface == GenesisProtocolFormulasInterface(0)) {
            return int(params.thresholdConstA * (e ** (orgBoostedProposalsCnt[_avatar]/params.thresholdConstB)));
        } else {
            return int((params.governanceFormulasInterface).threshold(_avatar));
        }
    }

    /**
     * @dev redeemAmount return the redeem amount which a certain staker is entitle to.
     * @param _proposalId the ID of the proposal
     * @param _beneficiary the beneficiary .
     * @return uint redeem amount .
     */
    function redeemAmount(bytes32 _proposalId,address _beneficiary) public view returns(uint) {
        bytes32 paramsHash = getParametersFromController(Avatar(proposals[_proposalId].avatar));
        Parameters memory params = parameters[paramsHash];
        if (params.governanceFormulasInterface == GenesisProtocolFormulasInterface(0)) {
            Proposal storage proposal = proposals[_proposalId];
            if (proposal.stakes[proposals[_proposalId].winningVote] == 0) {
              //this can be reached if the winningVote is 0
                return 0;
            }
            return (proposal.stakers[_beneficiary].amount * proposal.totalStakes) / proposal.stakes[proposals[_proposalId].winningVote];
        } else {
            return (params.governanceFormulasInterface).redeemAmount(_proposalId,_beneficiary);
        }
    }

    /**
     * @dev redeemProposerReputation return the redeem amount which a proposer is entitle to.
     * @param _proposalId the ID of the proposal
     * @return int proposer redeem reputation.
     */
    function redeemProposerReputation(bytes32 _proposalId) public view returns(int) {
        bytes32 paramsHash = getParametersFromController(Avatar(proposals[_proposalId].avatar));
        Parameters memory params = parameters[paramsHash];
        int rep;
        if (params.governanceFormulasInterface == GenesisProtocolFormulasInterface(0)) {
            Proposal storage proposal = proposals[_proposalId];
            if (proposal.winningVote == 0) {
                rep = 0;
            } else {
                rep = int(params.proposingRepRewardConstA + params.proposingRepRewardConstB * (proposal.votes[1]-proposal.votes[0]));
            }
        } else {
            rep = int((params.governanceFormulasInterface).redeemProposerReputation(_proposalId));
        }
        return rep;
    }

    /**
     * @dev redeemVoterAmount return the redeem amount which a voter is entitle to.
     * @param _proposalId the ID of the proposal
     * @param _beneficiary the beneficiary .
     * @return uint proposer redeem reputation amount.
     */
    function redeemVoterAmount(bytes32 _proposalId, address _beneficiary) public view returns(uint) {
        bytes32 paramsHash = getParametersFromController(Avatar(proposals[_proposalId].avatar));
        Parameters memory params = parameters[paramsHash];
        Proposal storage proposal = proposals[_proposalId];
        if (proposal.totalVotes == 0)
           return 0;

        if (params.governanceFormulasInterface == GenesisProtocolFormulasInterface(0)) {
            return (proposal.votersStakes * (proposal.voters[_beneficiary].reputation / proposal.totalVotes));
        } else {
            return (params.governanceFormulasInterface).redeemVoterAmount(_proposalId,_beneficiary);
        }
    }

    /**
     * @dev redeemVoterReputation return the redeem reputation which a voter is entitle to.
     * @param _proposalId the ID of the proposal
     * @param _beneficiary the beneficiary .
     * @return uint proposer redeem reputation amount.
     */
    function redeemVoterReputation(bytes32 _proposalId, address _beneficiary) public view returns(int) {
        bytes32 paramsHash = getParametersFromController(Avatar(proposals[_proposalId].avatar));
        Parameters memory params = parameters[paramsHash];
        Proposal storage proposal = proposals[_proposalId];
        int rep;
        if (proposal.state == ProposalState.Closed) {
           //no reputation flow occurs so give back reputation for the voter
            return int((proposal.voters[_beneficiary].reputation * params.votersReputationLossRatio)/100);
        }
        if (proposal.totalVotes == 0) {
            return 0;
         }
        if (proposal.voters[_beneficiary].preBoosted && (proposal.winningVote == proposal.voters[_beneficiary].vote )) {
        //give back reputation for the voter
            rep = int((proposal.voters[_beneficiary].reputation * params.votersReputationLossRatio)/100);
        }

        //80% (configurable, changeable) of the amount of the lost reputation is divided by the successful PB voters, in proportion to their reputation.
        return rep + int((proposal.voters[_beneficiary].reputation * ((proposal.lostReputation * params.votersGainRepRatioFromLostRep)/100))/proposal.totalVotes);
    }

    /**
     * @dev redeemStakerRepAmount return the redeem amount which a staker is entitle to.
     * @param _proposalId the ID of the proposal
     * @param _beneficiary the beneficiary .
     * @return uint proposer redeem reputation amount.
     */
    function redeemStakerRepAmount(bytes32 _proposalId, address _beneficiary) public view returns(int) {
        bytes32 paramsHash = getParametersFromController(Avatar(proposals[_proposalId].avatar));
        Parameters memory params = parameters[paramsHash];
        Proposal storage proposal = proposals[_proposalId];
        int rep;
        if ((proposal.stakers[_beneficiary].amount>0) &&
             (proposal.stakers[_beneficiary].vote == proposal.winningVote)) {
          //The rest (20%) of lost reputation is divided between the successful staker, in proportion to their stake.
            rep = int((proposal.stakers[_beneficiary].amount * ((proposal.lostReputation * (100 - params.votersGainRepRatioFromLostRep))/100)) / proposal.stakes[proposal.winningVote]);
        }
        return rep;
    }

  /**
   * @dev getNumberOfChoices returns the number of choices possible in this proposal
   * @param _proposalId the ID of the proposals
   * @return uint that contains number of choices
   */
    function getNumberOfChoices(bytes32 _proposalId) public constant returns(uint) {
        return proposals[_proposalId].numOfChoices;
    }

  /**
   * @dev voteInfo returns the vote and the amount of reputation of the user committed to this proposal
   * @param _proposalId the ID of the proposal
   * @param _voter the address of the voter
   * @return uint vote - the voters vote
   *        uint reputation - amount of reputation committed by _voter to _proposalId
   */
    function voteInfo(bytes32 _proposalId, address _voter) public constant returns(uint, uint) {
        Voter memory voter = proposals[_proposalId].voters[_voter];
        return (voter.vote, voter.reputation);
    }

    /**
     * @dev votesStatus returns the number of yes, no, and abstain and if the proposal is ended of a given proposal id
     * @param _proposalId the ID of the proposal
     * @return votes array of votes for each choice
     */
    function votesStatus(bytes32 _proposalId) public constant returns(uint[11] votes) {
        Proposal storage proposal = proposals[_proposalId];
        for (uint cnt = 0; cnt < proposal.numOfChoices; cnt++) {
            votes[cnt] = proposal.votes[cnt];
        }
    }

    /**
      * @dev isVotable check if the proposal is votable
      * @param _proposalId the ID of the proposal
      * @return bool true or false
    */
    function isVotable(bytes32 _proposalId) public constant returns(bool) {
        return ((proposals[_proposalId].state == ProposalState.PreBoosted)||(proposals[_proposalId].state == ProposalState.Boosted)||(proposals[_proposalId].state == ProposalState.QuietEndingPeriod));
    }

    /**
      * @dev proposalStatus return the total votes and stakes for a given proposal
      * @param _proposalId the ID of the proposal
      * @return uint totalVotes
      * @return uint totalStakes
      * @return uint voterStakes
    */
    function proposalStatus(bytes32 _proposalId) public constant returns(uint, uint, uint) {
        return (proposals[_proposalId].totalVotes, proposals[_proposalId].totalStakes, proposals[_proposalId].votersStakes);
    }

    /**
      * @dev totalReputationSupply return the total reputation supply for a given proposal
      * @param _proposalId the ID of the proposal
      * @return uint total reputation supply
    */
    function totalReputationSupply(bytes32 _proposalId) public constant returns(uint) {
        return Avatar(proposals[_proposalId].avatar).nativeReputation().totalSupply();
    }

    /**
      * @dev proposalAvatar return the avatar for a given proposal
      * @param _proposalId the ID of the proposal
      * @return uint total reputation supply
    */
    function proposalAvatar(bytes32 _proposalId) public constant returns(address) {
        return (proposals[_proposalId].avatar);
    }

    /**
      * @dev scoreThresholdParams return the score threshold params for a given
      * organization.
      * @param _avatar the organization's avatar
      * @return uint thresholdConstA
      * @return uint thresholdConstB
    */
    function scoreThresholdParams(address _avatar) public constant returns(uint,uint) {
        bytes32 paramsHash = getParametersFromController(Avatar(_avatar));
        Parameters memory params = parameters[paramsHash];
        return (params.thresholdConstA,params.thresholdConstB);
    }

    /**
      * @dev staker return the vote and stake amount for a given proposal and staker
      * @param _proposalId the ID of the proposal
      * @param _staker staker address
      * @return uint vote
      * @return uint amount
    */
    function staker(bytes32 _proposalId,address _staker) public constant returns(uint,uint) {
        return (proposals[_proposalId].stakers[_staker].vote,proposals[_proposalId].stakers[_staker].amount);
    }

    /**
      * @dev voteStake return the amount stakes for a given proposal and vote
      * @param _proposalId the ID of the proposal
      * @param _vote vote number
      * @return uint stake amount
    */
    function voteStake(bytes32 _proposalId,uint _vote) public constant returns(uint) {
        return proposals[_proposalId].stakes[_vote];
    }

    /**
      * @dev voteStake return the winningVote for a given proposal
      * @param _proposalId the ID of the proposal
      * @return uint winningVote
    */
    function winningVote(bytes32 _proposalId) public constant returns(uint) {
        return proposals[_proposalId].winningVote;
    }

    /**
      * @dev voteStake return the state for a given proposal
      * @param _proposalId the ID of the proposal
      * @return ProposalState proposal state
    */
    function state(bytes32 _proposalId) public constant returns(ProposalState) {
        return proposals[_proposalId].state;
    }

    /**
     * @dev Vote for a proposal, if the voter already voted, cancel the last vote and set a new one instead
     * @param _proposalId id of the proposal
     * @param _voter used in case the vote is cast for someone else
     * @param _vote a value between 0 to and the proposal's number of choices.
     * @param _rep how many reputation the voter would like to stake for this vote.
     *         if  _rep==0 so the voter full reputation will be use.
     * @return true in case of proposal execution otherwise false
     * throws if proposal is not open or if it has been executed
     * NB: executes the proposal if a decision has been reached
     */
    function internalVote(bytes32 _proposalId, address _voter, uint _vote, uint _rep) private returns(bool) {

        if (execute(_proposalId)) {
            return true;
        }

        bytes32 paramsHash = getParametersFromController(Avatar(proposals[_proposalId].avatar));
        Parameters memory params = parameters[paramsHash];
        Proposal storage proposal = proposals[_proposalId];
        // Check valid vote:
        require(_vote < proposal.numOfChoices);

        // Check voter has enough reputation:
        uint reputation = Avatar(proposal.avatar).nativeReputation().reputationOf(_voter);
        require(reputation >= _rep);
        uint rep = _rep;
        if (rep == 0) {
            rep = reputation;
        }
        // If this voter has already voted, return false.
        if (proposal.voters[_voter].reputation != 0) {
            return false;
        }
        // The voting itself:
        proposal.votes[_vote] = rep.add(proposal.votes[_vote]);
        if (proposal.votes[_vote] > proposal.votes[proposal.winningVote]) {
           // solium-disable-next-line security/no-block-members
            uint _now = now;
            if ((proposal.state == ProposalState.QuietEndingPeriod) ||
               ((proposal.state == ProposalState.Boosted) && ((_now - proposal.boostedPhaseTime) >= (params.boostedVotePeriodLimit - params.quietEndingPeriod)))) {
                //quietEndingPeriod
                proposal.boostedPhaseTime = _now;
                if (proposal.state != ProposalState.QuietEndingPeriod) {
                    proposal.boostedVotePeriodLimit = params.quietEndingPeriod;
                    proposal.state = ProposalState.QuietEndingPeriod;
                }
            }
            proposal.winningVote = _vote;
        }
        proposal.totalVotes = rep.add(proposal.totalVotes);
        if (proposal.state != ProposalState.Boosted) {
            uint reputationDeposit = (params.votersReputationLossRatio * rep)/100;
            ControllerInterface(Avatar(proposal.avatar).owner()).mintReputation((-1) * int(reputationDeposit),_voter,proposal.avatar);
            proposal.lostReputation += reputationDeposit;
        }
        proposal.voters[_voter] = Voter({
            reputation: rep,
            vote: _vote,
            preBoosted:(proposal.state == ProposalState.PreBoosted)
        });
        // Event:
        VoteProposal(_proposalId, _voter, _vote, reputation);
        // execute the proposal if this vote was decisive:
        return execute(_proposalId);
    }

    /**
     * @dev _score return the proposal score
     * For dual choice proposal S = (W+) - (W-)
     * For multiple choice proposal S = W * (R*R)/(totalRep*totalRep)
     * @param _proposalId the ID of the proposal
     * @param _totalSupply reputation total supply
     * @return int proposal score.
     */
    function _score(bytes32 _proposalId, uint _totalSupply) private view returns(int) {
        Proposal storage proposal = proposals[_proposalId];
        if (proposal.numOfChoices == 2) {
            return int(proposal.stakes[1]) - int(proposal.stakes[0]);
        }else {
            return int(((proposal.totalStakes+proposal.votersStakes) * (proposal.totalVotes**2))/(_totalSupply**2));
        }
    }
}
