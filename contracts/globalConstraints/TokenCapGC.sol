pragma solidity ^0.4.18;

import "zeppelin-solidity/contracts/token/StandardToken.sol";


/**
 * @title Token Cap Global Constraint
 * @dev A simple global constraint to cap the number of tokens.
 */

contract TokenCapGC {
    // A set of parameters, on which the cap will be checked:
    struct Parameters {
        StandardToken token;
        uint cap;
    }

    // Mapping from the hash of the parameters to the parameters themselves:
    mapping (bytes32=>Parameters) public params;


    /**
     * @dev adding a new set of parameters
     * @param  _token the token to add to the params.
     * @param _cap the cap to check the total supply against.
     * @return the calculated parameters hash
     */
    function setParameters(StandardToken _token, uint _cap) public returns(bytes32) {
        bytes32 paramsHash = getParametersHash(_token, _cap);
        params[paramsHash].token = _token;
        params[paramsHash].cap = _cap;
        return paramsHash;
    }

    /**
     * @dev calculate and returns the hash of the given parameters
     * @param  _token the token to add to the params.
     * @param _cap the cap to check the total supply against.
     * @return the calculated parameters hash
     */
    function getParametersHash(StandardToken _token, uint _cap) public pure returns(bytes32) {
        return (keccak256(_token, _cap));
    }

    /**
     * @dev check the constraint after the action.
     * This global constraint only checks the state after the action, so here we just return true:
     * @return true
     */
    function pre(address, bytes32, bytes) public pure returns(bool) {
        return true;
    }

    /**
     * @dev check the total supply cap.
     * @param  _paramsHash the parameters hash to check the total supply cap against.
     * @return bool which represents a success
     */
    function post(address, bytes32 _paramsHash, bytes) public view returns(bool) {
        if ((params[_paramsHash].token != StandardToken(0)) &&
            ( params[_paramsHash].token.totalSupply() > params[_paramsHash].cap)) {
            return false;
          }
        return true;
    }
}
