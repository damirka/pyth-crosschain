module pyth::set_data_sources_tests;

use pyth::data_source;
use pyth::pyth_tests::{Self, setup_test, take_wormhole_and_pyth_states};
use pyth::state;
use sui::coin;
use sui::test_scenario;
use wormhole::bytes32;
use wormhole::external_address;

const SET_DATA_SOURCES_VAA: vector<u8> =
    x"01000000000100b29ee59868b9066b04d8d59e1c7cc66f0678eaf4c58b8c87e4405d6de615f64b04da4025719aeed349e03900f37829454d62cc7fc7bca80328c31fe40be7b21b010000000000000000000163278d271099bfd491951b3e648f08b1c71631e4a53674ad43e8f9f98068c3850000000000000001015054474d0102001503001ae101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa71001aa27839d641b07743c0cb5f68c51f8cd31d2c0762bec00dc6fcd25433ef1ab5b60001f346195ac02f37d60d4db8ffa6ef74cb1be3550047543a4a9ee9acf4d78697b0";
// VAA Info:
//   module name: 0x1
//   action: 2
//   chain: 21
//   data sources (chain, addr) pairs: [(1, 0xf346195ac02f37d60d4db8ffa6ef74cb1be3550047543a4a9ee9acf4d78697b0), (26, 0xa27839d641b07743c0cb5f68c51f8cd31d2c0762bec00dc6fcd25433ef1ab5b6), (26, 0xe101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa71)]

const DEPLOYER: address = @0x1234;
const DEFAULT_BASE_UPDATE_FEE: u64 = 0;
const DEFAULT_COIN_TO_MINT: u64 = 0;

#[test]
fun set_data_sources() {
    let (mut scenario, test_coins, clock) = setup_test(
        500,
        1,
        x"63278d271099bfd491951b3e648f08b1c71631e4a53674ad43e8f9f98068c385",
        pyth_tests::data_sources_for_test_vaa(),
        vector[x"13947bd48b18e53fdaeee77f3473391ac727c638"],
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let verified_vaa = wormhole::vaa::parse_and_verify(
        &worm_state,
        SET_DATA_SOURCES_VAA,
        &clock,
    );

    let receipt = pyth::governance::verify_vaa(&pyth_state, verified_vaa);

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::governance::execute_governance_instruction(&mut pyth_state, receipt);

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    // assert data sources are set correctly

    assert!(
        state::is_valid_data_source(
            &pyth_state,
            data_source::new(
                1,
                external_address::new(
                    bytes32::from_bytes(
                        x"f346195ac02f37d60d4db8ffa6ef74cb1be3550047543a4a9ee9acf4d78697b0",
                    ),
                ),
            ),
        ),
        0,
    );
    assert!(
        state::is_valid_data_source(
            &pyth_state,
            data_source::new(
                26,
                external_address::new(
                    bytes32::from_bytes(
                        x"a27839d641b07743c0cb5f68c51f8cd31d2c0762bec00dc6fcd25433ef1ab5b6",
                    ),
                ),
            ),
        ),
        0,
    );
    assert!(
        state::is_valid_data_source(
            &pyth_state,
            data_source::new(
                26,
                external_address::new(
                    bytes32::from_bytes(
                        x"e101faedac5851e32b9b23b5f9411a8c2bac4aae3ed4dd7b811dd1a72ea4aa71",
                    ),
                ),
            ),
        ),
        0,
    );

    // clean up
    coin::burn_for_testing(test_coins);
    pyth_tests::cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}
