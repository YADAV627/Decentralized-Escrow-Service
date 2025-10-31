// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title DecentralizedEscrow
 * @dev Peer-to-peer escrow service with dispute resolution and multi-signature releases
 */
contract DecentralizedEscrow {
    
    enum EscrowStatus { 
        AWAITING_PAYMENT, 
        AWAITING_DELIVERY, 
        COMPLETE, 
        REFUNDED, 
        DISPUTED 
    }

    struct Escrow {
        address payable buyer;
        address payable seller;
        address arbitrator;
        uint256 amount;
        EscrowStatus status;
        uint256 createdAt;
        uint256 deadline;
        bool buyerApproved;
        bool sellerApproved;
        bool arbitratorDecided;
        string description;
    }

    // Mapping from escrow ID to Escrow details
    mapping(uint256 => Escrow) public escrows;
    
    // Counter for escrow IDs
    uint256 public escrowCounter;
    
    // Fee percentage (in basis points, 100 = 1%)
    uint256 public platformFee = 250; // 2.5%
    address payable public platformWallet;
    
    // Events
    event EscrowCreated(
        uint256 indexed escrowId,
        address indexed buyer,
        address indexed seller,
        uint256 amount,
        uint256 deadline
    );
    event PaymentDeposited(uint256 indexed escrowId, uint256 amount);
    event EscrowReleased(uint256 indexed escrowId, uint256 amount);
    event EscrowRefunded(uint256 indexed escrowId, uint256 amount);
    event DisputeRaised(uint256 indexed escrowId, address indexed raisedBy);
    event DisputeResolved(uint256 indexed escrowId, address indexed winner);
    event ApprovalGiven(uint256 indexed escrowId, address indexed approver);

    modifier onlyBuyer(uint256 escrowId) {
        require(msg.sender == escrows[escrowId].buyer, "Only buyer can call this");
        _;
    }

    modifier onlySeller(uint256 escrowId) {
        require(msg.sender == escrows[escrowId].seller, "Only seller can call this");
        _;
    }

    modifier onlyArbitrator(uint256 escrowId) {
        require(msg.sender == escrows[escrowId].arbitrator, "Only arbitrator can call this");
        _;
    }

    modifier inStatus(uint256 escrowId, EscrowStatus status) {
        require(escrows[escrowId].status == status, "Invalid escrow status");
        _;
    }

    constructor(address payable _platformWallet) {
        require(_platformWallet != address(0), "Invalid platform wallet");
        platformWallet = _platformWallet;
    }

    /**
     * @dev Create a new escrow agreement
     * @param seller Address of the seller
     * @param arbitrator Address of neutral third-party arbitrator
     * @param deadline Timestamp when automatic refund becomes available
     * @param description Description of the transaction
     * @return escrowId The ID of the newly created escrow
     */
    function createEscrow(
        address payable seller,
        address arbitrator,
        uint256 deadline,
        string memory description
    ) public payable returns (uint256) {
        require(msg.value > 0, "Escrow amount must be greater than 0");
        require(seller != address(0) && seller != msg.sender, "Invalid seller address");
        require(arbitrator != address(0), "Invalid arbitrator address");
        require(deadline > block.timestamp, "Deadline must be in the future");

        escrowCounter++;
        uint256 escrowId = escrowCounter;

        escrows[escrowId] = Escrow({
            buyer: payable(msg.sender),
            seller: seller,
            arbitrator: arbitrator,
            amount: msg.value,
            status: EscrowStatus.AWAITING_DELIVERY,
            createdAt: block.timestamp,
            deadline: deadline,
            buyerApproved: false,
            sellerApproved: false,
            arbitratorDecided: false,
            description: description
        });

        emit EscrowCreated(escrowId, msg.sender, seller, msg.value, deadline);
        emit PaymentDeposited(escrowId, msg.value);

        return escrowId;
    }

    /**
     * @dev Release funds to seller (requires buyer approval or arbitrator decision)
     * @param escrowId ID of the escrow
     */
    function releaseFunds(uint256 escrowId) 
        public 
        inStatus(escrowId, EscrowStatus.AWAITING_DELIVERY) 
    {
        Escrow storage escrow = escrows[escrowId];
        
        require(
            msg.sender == escrow.buyer || 
            msg.sender == escrow.arbitrator,
            "Only buyer or arbitrator can release funds"
        );

        if (msg.sender == escrow.buyer) {
            escrow.buyerApproved = true;
        } else if (msg.sender == escrow.arbitrator) {
            escrow.arbitratorDecided = true;
        }

        emit ApprovalGiven(escrowId, msg.sender);

        // Release funds if buyer approved OR arbitrator decided
        if (escrow.buyerApproved || escrow.arbitratorDecided) {
            escrow.status = EscrowStatus.COMPLETE;
            
            // Calculate platform fee
            uint256 fee = (escrow.amount * platformFee) / 10000;
            uint256 sellerAmount = escrow.amount - fee;
            
            // Transfer funds
            platformWallet.transfer(fee);
            escrow.seller.transfer(sellerAmount);
            
            emit EscrowReleased(escrowId, sellerAmount);
        }
    }

    /**
     * @dev Refund buyer (available after deadline or by arbitrator decision)
     * @param escrowId ID of the escrow
     */
    function refundBuyer(uint256 escrowId) 
        public 
        inStatus(escrowId, EscrowStatus.AWAITING_DELIVERY) 
    {
        Escrow storage escrow = escrows[escrowId];
        
        bool canRefund = false;
        
        // Arbitrator can refund anytime
        if (msg.sender == escrow.arbitrator) {
            canRefund = true;
            escrow.arbitratorDecided = true;
        }
        // Buyer can refund after deadline
        else if (msg.sender == escrow.buyer && block.timestamp >= escrow.deadline) {
            canRefund = true;
        }
        // Seller can initiate refund
        else if (msg.sender == escrow.seller) {
            canRefund = true;
        }
        
        require(canRefund, "Refund not authorized or deadline not reached");
        
        escrow.status = EscrowStatus.REFUNDED;
        escrow.buyer.transfer(escrow.amount);
        
        emit EscrowRefunded(escrowId, escrow.amount);
    }

    /**
     * @dev Raise a dispute (moves escrow to disputed state for arbitrator resolution)
     * @param escrowId ID of the escrow
     */
    function raiseDispute(uint256 escrowId) 
        public 
        inStatus(escrowId, EscrowStatus.AWAITING_DELIVERY) 
    {
        Escrow storage escrow = escrows[escrowId];
        
        require(
            msg.sender == escrow.buyer || msg.sender == escrow.seller,
            "Only buyer or seller can raise dispute"
        );
        
        escrow.status = EscrowStatus.DISPUTED;
        emit DisputeRaised(escrowId, msg.sender);
    }

    /**
     * @dev Arbitrator resolves dispute by choosing winner
     * @param escrowId ID of the escrow
     * @param releaseToSeller True to release to seller, false to refund buyer
     */
    function resolveDispute(uint256 escrowId, bool releaseToSeller) 
        public 
        onlyArbitrator(escrowId)
        inStatus(escrowId, EscrowStatus.DISPUTED) 
    {
        Escrow storage escrow = escrows[escrowId];
        escrow.arbitratorDecided = true;
        
        if (releaseToSeller) {
            escrow.status = EscrowStatus.COMPLETE;
            
            uint256 fee = (escrow.amount * platformFee) / 10000;
            uint256 sellerAmount = escrow.amount - fee;
            
            platformWallet.transfer(fee);
            escrow.seller.transfer(sellerAmount);
            
            emit DisputeResolved(escrowId, escrow.seller);
            emit EscrowReleased(escrowId, sellerAmount);
        } else {
            escrow.status = EscrowStatus.REFUNDED;
            escrow.buyer.transfer(escrow.amount);
            
            emit DisputeResolved(escrowId, escrow.buyer);
            emit EscrowRefunded(escrowId, escrow.amount);
        }
    }

    /**
     * @dev Get escrow details
     * @param escrowId ID of the escrow
     */
    function getEscrowDetails(uint256 escrowId) 
        public 
        view 
        returns (
            address buyer,
            address seller,
            address arbitrator,
            uint256 amount,
            EscrowStatus status,
            uint256 deadline,
            string memory description
        ) 
    {
        Escrow memory escrow = escrows[escrowId];
        return (
            escrow.buyer,
            escrow.seller,
            escrow.arbitrator,
            escrow.amount,
            escrow.status,
            escrow.deadline,
            escrow.description
        );
    }

    /**
     * @dev Update platform fee (only contract owner)
     */
    function updatePlatformFee(uint256 newFee) public {
        require(msg.sender == platformWallet, "Only platform can update fee");
        require(newFee <= 1000, "Fee cannot exceed 10%");
        platformFee = newFee;
    }
}
