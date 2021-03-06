// SPDX-License-Identifier: GPL-3.0-only
pragma solidity ^0.8.3;

interface IMVG {
    function checkDone() external returns(bool);
}

contract DoneChecker {
    IMVG public mvg;

    event Result(bool value);

    constructor(address mvg_) {
        mvg = IMVG(mvg_);
    }

    function checkDone() external {
        bool result = mvg.checkDone();

        emit Result(result);
    }
}
