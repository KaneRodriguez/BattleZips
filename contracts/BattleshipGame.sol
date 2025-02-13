//SPDX-License-Identifier: MIT
pragma solidity >=0.8.11;

import "./IBattleshipGame.sol";
import "hardhat/console.sol";

contract BattleshipGame is IBattleshipGame {
    /// MODIFIERS ///

    /**
     * Ensure a message sender is not currently playing another game
     */
    modifier canPlay() {
        require(playing[_msgSender()] == 0, "Reentrant");
        _;
    }

    /**
     * Determine whether message sender is allowed to call a turn function
     *
     * @param _game uint256 - the nonce of the game to check playability for
     */
    modifier myTurn(uint256 _game) {
        require(playing[_msgSender()] == _game, "!Playing");
        require(games[_game].winner == address(0), "!Playable");
        address current = games[_game].nonce % 2 == 0
            ? games[_game].participants[0]
            : games[_game].participants[1];
        require(_msgSender() == current, "!Turn");
        _;
    }

    /**
     * Make sure game is joinable
     * Will have more conditions once shooting phase is implemented
     *
     * @param _game uint256 - the nonce of the game to check validity for
     */
    modifier joinable(uint256 _game) {
        require(_game != 0 && _game <= gameIndex, "out-of-bounds");
        require(
            games[_game].participants[0] != address(0) &&
                games[_game].participants[1] == address(0),
            "!Open"
        );
        _;
    }

    /// CONSTRUCTOR ///

    /**
     * Construct new instance of Battleship manager
     *
     * @param _forwarder address - the address of the erc2771 trusted forwarder
     * @param _bv address - the address of the initial board validity prover
     * @param _sv address - the address of the shot hit/miss prover
     */
    constructor(
        address _forwarder,
        address _bv,
        address _sv
    ) ERC2771Context(_forwarder) {
        bv = IBoardVerifier(_bv);
        sv = IShotVerifier(_sv);
    }

    /// MUTABLE FUNCTIONS ///

    function newGame(
        uint256 _boardHash,
        uint256[2] memory a,
        uint256[2] memory b_0,
        uint256[2] memory b_1,
        uint256[2] memory c
    ) external override canPlay {
        require(
            bv.verifyProof(a, [b_0, b_1], c, [_boardHash]),
            "Invalid Board Config!"
        );
        gameIndex++;
        games[gameIndex].participants[0] = _msgSender();
        games[gameIndex].boards[0] = _boardHash;
        playing[_msgSender()] = gameIndex;
        emit Started(gameIndex, _msgSender());
    }

    function joinGame(
        uint256 _game,
        uint256 _boardHash,
        uint256[2] memory a,
        uint256[2] memory b_0,
        uint256[2] memory b_1,
        uint256[2] memory c
    ) external override canPlay joinable(_game) {
        require(
            bv.verifyProof(a, [b_0, b_1], c, [_boardHash]),
            "Invalid Board Config!"
        );
        games[_game].participants[1] = _msgSender();
        games[_game].boards[1] = _boardHash;
        playing[_msgSender()] = _game;
        emit Joined(_game, _msgSender());
    }

    function firstTurn(uint256 _game, uint256[2] memory _shot)
        external
        override
        myTurn(_game)
    {
        Game storage game = games[_game];
        require(game.nonce == 0, "!Turn1");
        game.shots[game.nonce] = _shot;
        game.nonce++;
    }

    function turn(
        uint256 _game,
        bool _hit,
        uint256[2] memory _next,
        uint256[2] memory a,
        uint256[2] memory b_0,
        uint256[2] memory b_1,
        uint256[2] memory c
    ) external override myTurn(_game) {
        Game storage game = games[_game];
        require(game.nonce != 0, "Turn=0");
        // check proof
        uint256 boardHash = game.boards[game.nonce % 2];
        uint256[2] memory shot = game.shots[game.nonce - 1];
        uint256 hitInt;
        assembly {
            hitInt := _hit
        }
        require(
            sv.verifyProof(
                a,
                [b_0, b_1],
                c,
                [boardHash, shot[0], shot[1], hitInt]
            ),
            "Invalid turn proof"
        );
        // update game state
        game.hits[game.nonce - 1] = _hit;
        if (_hit) game.hitNonce[(game.nonce - 1) % 2]++;
        emit Shot(
            uint8(shot[0]),
            uint8(shot[1]),
            _game,
            _hit
        );
        // check if game over
        if (game.hitNonce[(game.nonce - 1) % 2] >= HIT_MAX) gameOver(_game);
        else {
            // add next shot
            game.shots[game.nonce] = _next;
            game.nonce++;
        }
    }

    /// VIEWABLE FUNCTIONS ///

    function gameState(uint256 _game)
        external
        view
        override
        returns (
            address[2] memory _participants,
            uint256[2] memory _boards,
            uint256 _turnNonce,
            uint256[2] memory _hitNonce,
            address _winner
        )
    {
        _participants = games[_game].participants;
        _boards = games[_game].boards;
        _turnNonce = games[_game].nonce;
        _hitNonce = games[_game].hitNonce;
        _winner = games[_game].winner;
    }

    /// INTERNAL FUNCTIONS ///

    /**
     * Handle transitioning game to finished state & paying out
     *
     * @param _game uint256 - the nonce of the game being finalized
     */
    function gameOver(uint256 _game) internal {
        Game storage game = games[_game];
        require(
            game.hitNonce[0] == HIT_MAX || game.hitNonce[1] == HIT_MAX,
            "!Over"
        );
        require(game.winner == address(0), "Over");
        game.winner = game.hitNonce[0] == HIT_MAX
            ? game.participants[0]
            : game.participants[1];
        emit Won(game.winner, _game, game.winner);
    }
}
