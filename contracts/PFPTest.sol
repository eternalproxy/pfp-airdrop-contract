
// SPDX-License-Identifier: MIT

pragma solidity ^0.8.15;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import "@openzeppelin/contracts/token/ERC721/extensions/IERC721Enumerable.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "./mocks/VRF/VRFConsumerMock.sol";
import "../ethereum/ERC721A.sol";
import "../ethereum/EPSInterface/IEPSDelegationRegister.sol";

/**
 * @dev These functions deal with verification of Merkle Trees proofs.
 *
 * The proofs can be generated using the JavaScript library
 * https://github.com/miguelmota/merkletreejs[merkletreejs].
 * Note: the hashing algorithm should be keccak256 and pair sorting should be enabled.
 *
 * See `test/utils/cryptography/MerkleProof.test.js` for some examples.
 */
library MerkleProof {
    /**
     * @dev Returns true if a `leaf` can be proved to be a part of a Merkle tree
     * defined by `root`. For this, a `proof` must be provided, containing
     * sibling hashes on the branch from the leaf to the root of the tree. Each
     * pair of leaves and each pair of pre-images are assumed to be sorted.
     */
    function verify(
        bytes32[] memory proof,
        bytes32 root,
        bytes32 leaf
    ) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    /**
     * @dev Returns the rebuilt hash obtained by traversing a Merklee tree up
     * from `leaf` using `proof`. A `proof` is valid if and only if the rebuilt
     * hash matches the root of the tree. When processing the proof, the pairs
     * of leafs & pre-images are assumed to be sorted.
     *
     * _Available since v4.4._
     */
    function processProof(bytes32[] memory proof, bytes32 leaf) internal pure returns (bytes32) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash <= proofElement) {
                // Hash(current computed hash + current element of the proof)
                computedHash = keccak256(abi.encodePacked(computedHash, proofElement));
            } else {
                // Hash(current element of the proof + current computed hash)
                computedHash = keccak256(abi.encodePacked(proofElement, computedHash));
            }
        }
        return computedHash;
    }
}

contract PFPTest is ERC721A, Ownable, VRFConsumerMock {
    using Strings for uint256;
    
    uint256 public constant MAX_TOKENS = 400;
    string public constant BASE_EXTENSION = ".json";
    string public _baseURIextended;
    address public _passAddress;
    bool public revealed = false;
    string public notRevealedUri = "";
    uint256 public randStartPos;
    bytes32 public immutable vrfKeyHash;
    bytes32 public request_id;
    IEPSDelegationRegister public immutable EPS;
    bytes32 public snapshotMerkleRoot;
    
    mapping (address => uint256) public _claimedAmount;
    
    error ClaimExceedsAllowance(uint128 claim, uint128 allowance);
    error InvalidProof();

    event WebaversePFPMint(uint256 amountMinted);

    event CollectionRevealed(uint256 randomStartPosition);

    constructor(
        address passAddress_,
        address epsAddress_,
        address _ChainlinkVRFCoordinator,
        address _ChainlinkLINKToken,
        bytes32 _ChainlinkKeyHash
    ) ERC721A("PFP", "PFP") VRFConsumerMock(_ChainlinkVRFCoordinator, _ChainlinkLINKToken) {
        _passAddress = passAddress_;
        vrfKeyHash = _ChainlinkKeyHash;
        EPS = IEPSDelegationRegister(epsAddress_); 
    }

    function setBaseURI(string memory baseURI_) external onlyOwner() {
        require(!revealed, "Collection revealed, cannot set URI");
        
        _baseURIextended = baseURI_;
    }

    function _baseURI() internal view virtual override returns (string memory) {
        return _baseURIextended;
    }
    
    function setPassContract(address passAddress_) public onlyOwner {
        _passAddress = passAddress_;
    }

    function getPassContract() public view returns (address) {
        return _passAddress;
    }

    function reveal() public onlyOwner {
      if(!revealed) {
        _getRandomNumber();
      }
    }

    function setNotRevealedURI(string memory _notRevealedURI) public onlyOwner {
        notRevealedUri = _notRevealedURI;
    }

    function setMerkleRoot(bytes32 merkleRoot) public onlyOwner returns (bytes32) {
        snapshotMerkleRoot = merkleRoot;
        return snapshotMerkleRoot;
    }

    /**
     * Returns the tokenURI
     * Random starting positions can only be set before the token's metadata is revealed.
     *
     */
    function tokenURI(uint256 tokenId) public view virtual override returns (string memory)
    {
        if(revealed == false) {
            return notRevealedUri;
        }
        string memory currentBaseURI = _baseURI();
        return bytes(currentBaseURI).length > 0
            ? string(abi.encodePacked(currentBaseURI, ((tokenId+randStartPos) % MAX_TOKENS).toString(), BASE_EXTENSION))
            : "";
    }

    function claimTokens(bytes32[] calldata merkleProof, uint256 numberOfTokens, uint256 allowance ) external {
        address[] memory coldWallets = EPS.getAddresses(msg.sender, _passAddress, 1, true, true);
        require(totalSupply() + numberOfTokens <= MAX_TOKENS, "Claim would exceed max supply of tokens!");
        for (uint256 i = 0; i < coldWallets.length; i++) {
            address coldWallet = coldWallets[i];
            if (MerkleProof.verify(merkleProof, snapshotMerkleRoot, keccak256(abi.encodePacked(coldWallet, '_', allowance)))) {
                if(_claimedAmount[coldWallet] + numberOfTokens <= allowance ) {
                    _safeMint(msg.sender, numberOfTokens);
                    _claimedAmount[coldWallet] += numberOfTokens;
                    emit WebaversePFPMint(numberOfTokens);
                    // Function exit 1: success
                    return;
                } else {
                    // Function exit 2: claim exceeds allowance
                    revert ClaimExceedsAllowance(uint128(numberOfTokens), uint128(allowance - _claimedAmount[coldWallet]));
                }
            }
        }
        // Function exit 3: no matching proof
        revert InvalidProof();
    }

    function withdraw() public onlyOwner {
        uint256 balance = address(this).balance;
        payable(msg.sender).transfer(balance);
    }

    function _getRandomNumber() internal returns (bytes32 requestId) {
        uint256 fee = 0.1 * 10 ** 18;
        //require( LINK.balanceOf(address(this)) >= fee, "YOU HAVE TO SEND LINK TOKEN TO THIS CONTRACT");
        return requestRandomness(vrfKeyHash, fee);
    }

    // this is callback, it will be called by the vrf coordinator
    function fulfillRandomness(bytes32 requestId, uint256 randomness) internal override {
        request_id = requestId;
        if(randStartPos==0) {
          randStartPos = randomness % MAX_TOKENS;
          revealed = true;
          emit CollectionRevealed(randStartPos);
        }
    }

}