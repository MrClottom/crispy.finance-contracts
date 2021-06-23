// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../lib/FeeTaker.sol";
import "../../lib/interfaces/IHex.sol";
import "../../lib/TwoWayMapping.sol";

contract HexStakeTokenizer is ERC721, FeeTaker {
    using SafeERC20 for IHex;
    using TwoWayMapping for TwoWayMapping.UintToUint;

    IHex public immutable hexToken;
    uint256 public totalIssuedTokens;
    uint256 public totalOpenStakes;
    string public currentBaseURI;

    // stores stakeId to make sure stakes cannot be confused
    mapping(uint256 => uint256) internal _stakeIdOfToken;
    TwoWayMapping.UintToUint internal _tokenIdToStakeIndex;

    constructor(uint256 _fee, IHex _hexToken)
        ERC721("Crispy.finance tokenized hex stakes", "CHXS")
        FeeTaker(_fee)
    {
        hexToken = _hexToken;
    }

    function createStakesFor(
        address _recipient,
        uint256[] memory _stakeAmounts,
        uint256[] memory _stakeDays,
        uint256 _maxFee,
        uint256 _upfrontTotal
    )
        external
    {
        require(_stakeAmounts.length == _stakeDays.length, "CHXS: Input length mismatch");
        _importFundsWithFee(_upfrontTotal, _maxFee);
        uint256 realTotal;
        for (uint256 i; i < _stakeAmounts.length; i++) {
            uint256 stakeAmount = _stakeAmounts[i];
            realTotal += stakeAmount;
            _issueNewTokenFor(_recipient, stakeAmount, _stakeDays[i]);
        }
        uint256 stakeCost = _addFeeForTotal(realTotal, hexToken);
        require(_upfrontTotal >= stakeCost, "CHXS: Insufficient funds");
        unchecked {
            uint256 refundAmount = _upfrontTotal - stakeCost;
            if (refundAmount > 0) hexToken.safeTransfer(msg.sender, refundAmount);
        }
    }

    function createStakeFor(
        address _recipient,
        uint256 _totalAmount,
        uint256 _stakeDays,
        uint256 _maxFee
    )
        external
    {
        _importFundsWithFee(_totalAmount, _maxFee);
        uint256 stakeAmount = _takeFeeFrom(_totalAmount, hexToken);
        _issueNewTokenFor(_recipient, stakeAmount, _stakeDays);
    }

    function setBaseURI(string calldata _newBaseURI) external onlyOwner {
        currentBaseURI = _newBaseURI;
    }

    function unstakeManyTo(address _recipient, uint256[] memory _tokenIds)
        external
    {
        uint256 balanceBefore = hexToken.balanceOf(address(this));
        for (uint256 i; i < _tokenIds.length; i++) {
            _redeemToken(_tokenIds[i]);
        }
        uint256 balanceAfter = hexToken.balanceOf(address(this));
        hexToken.safeTransfer(_recipient, balanceAfter - balanceBefore);
    }

    function unstakeTo(address _recipient, uint256 _tokenId) external {
        uint256 balanceBefore = hexToken.balanceOf(address(this));
        _redeemToken(_tokenId);
        uint256 balanceAfter = hexToken.balanceOf(address(this));
        hexToken.safeTransfer(_recipient, balanceAfter - balanceBefore);
    }

    function extendStakeLength(
        uint256 _tokenId,
        uint256 _newStakeDays,
        uint256 _maxFee,
        uint256 _addedAmount
    )
        external
    {
        uint256 balanceBefore = hexToken.balanceOf(address(this));
        _importFundsWithFee(_addedAmount, _maxFee);
        (uint256 stakeIndex, uint256 stakeId) = _checkToken(_tokenId);
        _closeStake(stakeIndex, stakeId);
        uint256 balanceAfter = hexToken.balanceOf(address(this));
        uint256 newStakeAmount = _takeFeeFrom(balanceAfter - balanceBefore, hexToken);
        _openStake(newStakeAmount, _newStakeDays, _tokenId);
    }

    /* should only be used if there is a bug in the sc and `unstakeTo` no longer
       works */
    function manuallyUnstakeTo(
        address _recipient,
        uint256 _tokenId,
        uint256 _stakeIndex
    )
        external
    {
        uint256 stakeId = _checkToken(_tokenId, _stakeIndex);
        uint256 balanceBefore = hexToken.balanceOf(address(this));
        _closeStake(_stakeIndex, stakeId);
        _burn(_tokenId);
        uint256 balanceAfter = hexToken.balanceOf(address(this));
        hexToken.safeTransfer(_recipient, balanceAfter - balanceBefore);
    }

    function getStakeIndex(uint256 _tokenId) public view returns (uint256) {
        return _tokenIdToStakeIndex.get(_tokenId);
    }

    function getTokenId(uint256 _stakeIndex) public view returns (uint256) {
        return _tokenIdToStakeIndex.rget(_stakeIndex);
    }

    function getTokenStakeId(uint256 _tokenId) public view returns (uint256) {
        return _stakeIdOfToken[_tokenId];
    }

    function _importFundsWithFee(uint256 _total, uint256 _maxFee) internal {
        _checkFeeAtMost(_maxFee);
        if (_total > 0) {
            hexToken.safeTransferFrom(msg.sender, address(this), _total);
        }
    }

    function _issueNewTokenFor(
        address _recipient,
        uint256 _stakeAmount,
        uint256 _stakeDays
    )
        internal
    {
        uint256 newTokenId = totalIssuedTokens++;
        _openStake(_stakeAmount, _stakeDays, newTokenId);
        _safeMint(_recipient, newTokenId);
    }

    function _openStake(
        uint256 _stakeAmount,
        uint256 _stakeDays,
        uint256 _tokenId
    )
        internal
    {
        uint256 newStakeIndex = totalOpenStakes++;
        _tokenIdToStakeIndex.set(_tokenId, newStakeIndex);
        hexToken.stakeStart(_stakeAmount, _stakeDays);
        _stakeIdOfToken[_tokenId] = _getStakeIdOf(newStakeIndex);
    }

    function _redeemToken(uint256 _tokenId) internal {
        (uint256 stakeIndex, uint256 stakeId) = _checkToken(_tokenId);
        _closeStake(stakeIndex, stakeId);
        _burn(_tokenId);
    }

    function _checkToken(uint256 _tokenId)
        internal view returns (uint256 stakeIndex, uint256 stakeId)
    {
        stakeIndex = getStakeIndex(_tokenId);
        stakeId = _checkToken(_tokenId, stakeIndex);
    }

    function _checkToken(uint256 _tokenId, uint256 _stakeIndex)
        internal view returns (uint256 stakeId)
    {
        address owner = ownerOf(_tokenId);
        require(
            msg.sender == owner || isApprovedForAll(owner, msg.sender),
            "CHXS: Caller not approved"
        );
        stakeId = _getStakeIdOf(_stakeIndex);
        require(_stakeIdOfToken[_tokenId] == stakeId, "CHXS: Invalid stake index");
    }

    function _closeStake(uint256 _stakeIndex, uint256 _stakeId) internal {
        uint256 lastStakeIndex = --totalOpenStakes;
        if (_stakeIndex != lastStakeIndex) {
            uint256 topTokenId = getTokenId(lastStakeIndex);
            _tokenIdToStakeIndex.set(topTokenId, _stakeIndex);
        }
        hexToken.stakeEnd(_stakeIndex, uint40(_stakeId));
    }

    function _getStakeIdOf(uint256 _stakeIndex) internal view returns (uint256) {
        (uint40 stakeId,,,,,,) = hexToken.stakeLists(address(this), _stakeIndex);
        return uint256(stakeId);
    }

    function _baseURI() internal view override returns (string memory) {
        return currentBaseURI;
    }
}
