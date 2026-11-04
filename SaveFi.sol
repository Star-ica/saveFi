// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/*
 SaveFi — decentralized group savings (goal circles) + personal savings pots.

 Nothing here executes on its own. Withdrawals, cancellation and refunds are
 transactions sent by a member, the circle admin/owner or the pot beneficiary.
 The admin can NEVER move member funds: funds leave only via withdraw()/leave() and refund().
*/

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}

enum State { Open, Active, Completed, Cancelled }

struct Params {
    string name;
    address token;              // address(0) = native coin (BOT on a BOT-native chain); otherwise allowlisted ERC-20 (e.g. USDT)
    uint256 amount;             // contribution per member per round (token base units)
    uint32 period;              // seconds per round
    uint32 grace;               // seconds after a round deadline in which a payment is "late" but still accepted at the normal late fee
    uint16 rounds;              // number of contribution rounds (term = rounds * period)
    uint16 lateFeeBps;          // fee on late contributions (shared with remaining savers), max 20%
    uint16 earlyExitPenaltyBps; // penalty on early withdrawal (shared with remaining savers), max 50%
    uint8 maxMembers;
    bool inviteOnly;
    uint256 goalTarget;         // shared target; reaching it unlocks withdrawals
}

interface ISaveFiFactory {
    function owner() external view returns (address);
    function recordMember(address user) external;
}

abstract contract Guard {
    uint256 private _l = 1;
    modifier nonReentrant() { require(_l == 1, "reentrancy"); _l = 2; _; _l = 1; }
}

/* ───────────────────────── Factory + membership registry ───────────────────────── */
contract SaveFiFactory is ISaveFiFactory {
    address public override owner;
    uint32 public minPeriod = 1 hours;
    address[] private _circles;
    mapping(address => bool) public isCircle;
    mapping(address => bool) public tokenAllowed;               // address(0) allowed = native coin
    mapping(address => address[]) private _membership;          // registry: wallet => circles joined

    event CircleCreated(address indexed circle, address indexed creator);
    event MemberRecorded(address indexed circle, address indexed user);
    event TokenAllowed(address indexed token, bool allowed);
    event OwnerChanged(address indexed owner);

    modifier onlyOwner() { require(msg.sender == owner, "owner"); _; }

    constructor(address[] memory tokens) {
        owner = msg.sender;
        for (uint256 i; i < tokens.length; i++) { tokenAllowed[tokens[i]] = true; emit TokenAllowed(tokens[i], true); }
    }

    function createCircle(Params calldata p) external returns (address c) {
        require(bytes(p.name).length > 0 && bytes(p.name).length <= 64, "name");
        require(tokenAllowed[p.token], "token");
        require(p.amount > 0, "amount");
        require(p.maxMembers >= 2 && p.maxMembers <= 50, "members");
        require(p.period >= minPeriod && p.grace <= p.period, "timing");
        require(p.lateFeeBps <= 2000 && p.earlyExitPenaltyBps <= 5000, "bps");
        require(p.rounds >= 1 && p.rounds <= 520, "rounds");
        require(p.goalTarget > 0, "goal");
        c = address(new SaveFiCircle(address(this), msg.sender, p));
        isCircle[c] = true;
        _circles.push(c);
        emit CircleCreated(c, msg.sender);
    }

    address[] private _pots;
    event PotCreated(address indexed pot, address indexed beneficiary);
    /// Personal savings pot: one beneficiary, anyone can contribute.
    function createPot(string calldata name, address token, uint256 target, uint256 unlockTime, uint256 minContribution) external returns (address pot) {
        require(bytes(name).length > 0 && bytes(name).length <= 64, "name");
        require(tokenAllowed[token], "token");
        require(target > 0 && unlockTime > block.timestamp, "params");
        pot = address(new SavingsPot(address(this), msg.sender, name, token, target, unlockTime, minContribution));
        _pots.push(pot);
        emit PotCreated(pot, msg.sender);
    }
    function allPots() external view returns (address[] memory) { return _pots; }
    function emergencyPausePot(address pot, bool on) external onlyOwner { SavingsPot(pot).setPaused(on); }

    function recordMember(address user) external override {
        require(isCircle[msg.sender], "circle only");
        _membership[user].push(msg.sender);
        emit MemberRecorded(msg.sender, user);
    }

    function allCircles() external view returns (address[] memory) { return _circles; }
    function circlesOf(address user) external view returns (address[] memory) { return _membership[user]; }

    // Administrative / emergency controls
    function setTokenAllowed(address t, bool ok) external onlyOwner { tokenAllowed[t] = ok; emit TokenAllowed(t, ok); }
    function setMinPeriod(uint32 s) external onlyOwner { minPeriod = s; }
    function transferOwnership(address o) external onlyOwner { require(o != address(0)); owner = o; emit OwnerChanged(o); }
    function emergencyPause(address circle, bool on) external onlyOwner { require(isCircle[circle], "unknown"); SaveFiCircle(circle).setPaused(on); }
}

/* ───────── Goal circle: membership + contribution manager + goal vault + refunds ───────── */
contract SaveFiCircle is Guard {
    ISaveFiFactory public immutable factory;
    address public immutable admin;
    Params public p;
    State public state;
    bool public paused;
    uint256 public startTime;

    struct Member { bool active; uint256 contributed; uint256 bal; uint16 late; bool refunded; }
    mapping(address => Member) public mem;
    address[] private _members;
    mapping(address => bool) public invited;
    mapping(uint256 => mapping(address => bool)) public paid;   // round => member => contributed (prevents duplicates)

    uint256 public pool;            // all member funds held
    uint256 public totalContributed;
    uint256 public activeBal;       // sum of balances not yet withdrawn
    uint256 public penaltyPool;     // late fees + early-exit penalties, shared pro rata with remaining savers
    uint256 public refundPool;
    uint256 public totalOwed;

    event Joined(address indexed member);
    event Left(address indexed member);
    event Started(uint256 startTime);
    event Contributed(uint256 indexed round, address indexed member, uint256 amount, uint256 lateFee);
    event Withdrawn(address indexed member, uint256 paidOut, bool early);
    event Cancelled(address indexed by);
    event Refunded(address indexed member, uint256 amount);
    event Paused(bool on);

    modifier adminOrOwner() { require(msg.sender == admin || msg.sender == factory.owner() || msg.sender == address(factory), "auth"); _; }

    constructor(address f, address a, Params memory _p) { factory = ISaveFiFactory(f); admin = a; p = _p; }

    function getMembers() external view returns (address[] memory) { return _members; }
    function memberCount() external view returns (uint256) { return _members.length; }
    function roundDeadline(uint256 r) public view returns (uint256) { return startTime + (r + 1) * uint256(p.period); }
    function currentRound() public view returns (uint256) {
        if (state != State.Active) return 0;
        uint256 r = (block.timestamp - startTime) / p.period;
        return r >= p.rounds ? p.rounds - 1 : r;
    }
    function termEnd() public view returns (uint256) { return startTime + uint256(p.rounds) * p.period; }
    /// Withdrawals unlock when the shared target is reached or the term ends, whichever is first.
    function unlocked() public view returns (bool) { return state == State.Active && (block.timestamp >= termEnd() || totalContributed >= p.goalTarget); }

    function invite(address[] calldata who) external {
        require(msg.sender == admin, "admin");
        for (uint256 i; i < who.length; i++) invited[who[i]] = true;
    }

    /// Join by wallet. The circle starts (clock begins) when the last seat is filled.
    function join() external nonReentrant {
        require(state == State.Open && !paused, "not open");
        require(!mem[msg.sender].active, "already member");
        require(_members.length < p.maxMembers, "full");
        require(!p.inviteOnly || invited[msg.sender] || msg.sender == admin, "invite only");
        mem[msg.sender].active = true;
        _members.push(msg.sender);
        factory.recordMember(msg.sender);
        emit Joined(msg.sender);
        if (_members.length == p.maxMembers) { state = State.Active; startTime = block.timestamp; emit Started(startTime); }
    }

    /// Leave rules: Open -> just leave. Active -> withdraw your balance (early-exit penalty applies before unlock).
    function leave() external nonReentrant {
        Member storage m = mem[msg.sender];
        require(m.active, "not member");
        if (state == State.Open) {
            uint256 n = _members.length;
            for (uint256 i; i < n; i++) if (_members[i] == msg.sender) {
                for (uint256 j = i; j + 1 < n; j++) _members[j] = _members[j + 1];
                _members.pop(); break;
            }
            delete mem[msg.sender];
            emit Left(msg.sender);
        } else if (state == State.Active) _withdraw(msg.sender);
        else revert("final");
    }

    /// Deadline for round r = startTime + (r+1)*period. Missed-payment consequence: after the deadline the member
    /// can still pay, but owes the late fee (lateFeeBps) which goes to the shared penalty pool, and a late mark is recorded.
    function contribute(uint256 r) external payable nonReentrant {
        require(state == State.Active && !paused, "inactive");
        Member storage m = mem[msg.sender];
        require(m.active, "not member");
        require(r < p.rounds && r <= currentRound(), "round not open");
        require(!paid[r][msg.sender], "already paid");
        require(block.timestamp < termEnd(), "ended");
        uint256 fee;
        if (block.timestamp > roundDeadline(r)) { fee = p.amount * p.lateFeeBps / 10000; m.late++; }
        _pull(p.amount + fee);
        paid[r][msg.sender] = true;
        m.contributed += p.amount; m.bal += p.amount;
        totalContributed += p.amount; activeBal += p.amount; penaltyPool += fee; pool += p.amount + fee;
        emit Contributed(r, msg.sender, p.amount, fee);
    }

    function withdraw() external nonReentrant { _withdraw(msg.sender); }

    function _withdraw(address a) internal {
        require(state == State.Active && !paused, "inactive");
        Member storage m = mem[a];
        uint256 b = m.bal;
        require(m.active && b > 0, "no balance");
        uint256 out; bool early = !unlocked();
        if (!early) { uint256 extra = penaltyPool * b / activeBal; penaltyPool -= extra; out = b + extra; }
        else { uint256 pen = b * p.earlyExitPenaltyBps / 10000; penaltyPool += pen; out = b - pen; m.active = false; }
        m.bal = 0; activeBal -= b; pool -= out;
        if (!early && activeBal == 0) state = State.Completed;
        _push(a, out);
        emit Withdrawn(a, out, early);
    }

    /// Open: admin/owner may cancel. Active: only while paused. Remaining funds are refunded pro rata to balances.
    function cancel() external adminOrOwner {
        if (state == State.Open) state = State.Cancelled;
        else if (state == State.Active) {
            require(paused, "pause first");
            state = State.Cancelled;
            for (uint256 i; i < _members.length; i++) totalOwed += mem[_members[i]].bal;
            refundPool = pool;
        } else revert("final");
        emit Cancelled(msg.sender);
    }

    function refund() external nonReentrant {
        require(state == State.Cancelled, "not cancelled");
        Member storage m = mem[msg.sender];
        require(m.active && !m.refunded, "n/a");
        m.refunded = true;
        uint256 share = totalOwed > 0 ? m.bal * refundPool / totalOwed : 0;
        pool -= share;
        _push(msg.sender, share);
        emit Refunded(msg.sender, share);
    }

    /// Pause blocks join/contribute/withdraw. refund() always works after cancel.
    function setPaused(bool on) external adminOrOwner { paused = on; emit Paused(on); }

    function _pull(uint256 amt) internal {
        if (p.token == address(0)) { require(msg.value == amt, "bad value"); return; }
        require(msg.value == 0, "no native");
        _call(abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, address(this), amt));
    }
    function _push(address to, uint256 amt) internal {
        if (amt == 0) return;
        if (p.token == address(0)) { (bool ok, ) = to.call{value: amt}(""); require(ok, "send failed"); }
        else _call(abi.encodeWithSelector(IERC20.transfer.selector, to, amt));
    }
    function _call(bytes memory data) private {
        (bool ok, bytes memory ret) = p.token.call(data);
        require(ok && (ret.length == 0 || abi.decode(ret, (bool))), "token");
    }
}

/* ───────── Personal savings pot: one beneficiary, open contributions ───────── */
contract SavingsPot is Guard {
    address public immutable factory;
    address public immutable beneficiary;
    address public immutable token;            // address(0) = native coin
    string public name;
    uint256 public immutable target;
    uint256 public immutable unlockTime;
    uint256 public immutable minContribution;
    uint256 public total;                      // everything ever contributed (until cancelled)
    uint256 public withdrawn;
    bool public cancelled;
    bool public paused;
    mapping(address => uint256) public contributed;
    address[] private _contributors;

    event Contributed(address indexed from, uint256 amount);
    event Withdrawn(uint256 amount);
    event Cancelled();
    event Refunded(address indexed to, uint256 amount);

    constructor(address f, address b, string memory n, address t, uint256 tgt, uint256 unlock, uint256 minC) {
        factory = f; beneficiary = b; name = n; token = t; target = tgt; unlockTime = unlock; minContribution = minC;
    }

    function unlocked() public view returns (bool) { return total >= target || block.timestamp >= unlockTime; }
    function contributors() external view returns (address[] memory) { return _contributors; }

    /// Anyone may add to the pot. Top-ups from the same wallet are allowed (it is a gift/savings pot, not a fixed schedule).
    function contribute(uint256 amt) external payable nonReentrant {
        require(!cancelled && !paused, "closed");
        require(amt > 0 && amt >= minContribution, "too small");
        _pull(amt);
        if (contributed[msg.sender] == 0) _contributors.push(msg.sender);
        contributed[msg.sender] += amt; total += amt;
        emit Contributed(msg.sender, amt);
    }

    /// Only the beneficiary, only after target reached or unlock date. Partial withdrawals allowed; cannot exceed what is held.
    function withdraw(uint256 amt) external nonReentrant {
        require(msg.sender == beneficiary, "beneficiary only");
        require(!cancelled && !paused && unlocked(), "locked");
        require(amt > 0 && amt <= total - withdrawn, "amount");
        withdrawn += amt;
        _push(msg.sender, amt);
        emit Withdrawn(amt);
    }

    /// While still locked and untouched, the beneficiary can cancel; every contributor then refunds their own contribution.
    function cancel() external {
        require(msg.sender == beneficiary, "beneficiary only");
        require(!cancelled && !unlocked() && withdrawn == 0, "cannot cancel");
        cancelled = true; emit Cancelled();
    }

    function refund() external nonReentrant {
        require(cancelled, "not cancelled");
        uint256 a = contributed[msg.sender];
        require(a > 0, "nothing");
        contributed[msg.sender] = 0;
        _push(msg.sender, a);
        emit Refunded(msg.sender, a);
    }

    /// Emergency pause (beneficiary or factory owner) blocks contribute/withdraw; refund always works after cancel.
    function setPaused(bool on) external {
        require(msg.sender == beneficiary || msg.sender == factory || msg.sender == ISaveFiFactory(factory).owner(), "auth");
        paused = on;
    }

    function _pull(uint256 amt) internal {
        if (token == address(0)) { require(msg.value == amt, "bad value"); return; }
        require(msg.value == 0, "no native");
        _call(abi.encodeWithSelector(IERC20.transferFrom.selector, msg.sender, address(this), amt));
    }
    function _push(address to, uint256 amt) internal {
        if (token == address(0)) { (bool ok, ) = to.call{value: amt}(""); require(ok, "send failed"); }
        else _call(abi.encodeWithSelector(IERC20.transfer.selector, to, amt));
    }
    function _call(bytes memory d) private {
        (bool ok, bytes memory r) = token.call(d);
        require(ok && (r.length == 0 || abi.decode(r, (bool))), "token");
    }
}
