#[test_only]
module pyth::pyth_tests;

use pyth::accumulator;
use pyth::data_source::{Self, DataSource};
use pyth::deserialize;
use pyth::hot_potato_vector;
use pyth::price_feed;
use pyth::price_identifier;
use pyth::price_info::{Self, PriceInfo, PriceInfoObject};
use pyth::pyth::{Self, create_price_infos_hot_potato, update_single_price_feed};
use pyth::setup;
use pyth::state::State as PythState;
use sui::clock::{Self, Clock};
use sui::coin::{Self, Coin};
use sui::package;
use sui::sui::SUI;
use sui::test_scenario::{Self, Scenario, ctx, take_shared, return_shared};
use wormhole::bytes32;
use wormhole::cursor;
use wormhole::external_address;
use wormhole::setup::{Self as wormhole_setup, DeployerCap};
use wormhole::state::State as WormState;
use wormhole::vaa::{Self, VAA};

const DEPLOYER: address = @0x1234;
const ACCUMULATOR_TESTS_EMITTER_ADDRESS: vector<u8> =
    x"71f8dcb863d176e2c420ad6610cf687359612b6fb392e0642b0ca6b1f186aa3b";
const ACCUMULATOR_TESTS_INITIAL_GUARDIANS: vector<vector<u8>> = vector[
    x"7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
];
const DEFAULT_BASE_UPDATE_FEE: u64 = 50;
const DEFAULT_COIN_TO_MINT: u64 = 5000;
const BATCH_ATTESTATION_TEST_INITIAL_GUARDIANS: vector<vector<u8>> = vector[
    x"beFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe",
];

fun ACCUMULATOR_TESTS_DATA_SOURCE(): vector<DataSource> {
    vector[
        data_source::new(
            1,
            external_address::new(bytes32::from_bytes(ACCUMULATOR_TESTS_EMITTER_ADDRESS)),
        ),
    ]
}

fun get_verified_test_vaas(worm_state: &WormState, clock: &Clock): vector<VAA> {
    let test_vaas_: vector<vector<u8>> = vector[
        x"0100000000010036eb563b80a24f4253bee6150eb8924e4bdf6e4fa1dfc759a6664d2e865b4b134651a7b021b7f1ce3bd078070b688b6f2e37ce2de0d9b48e6a78684561e49d5201527e4f9b00000001001171f8dcb863d176e2c420ad6610cf687359612b6fb392e0642b0ca6b1f186aa3b0000000000000001005032574800030000000102000400951436e0be37536be96f0896366089506a59763d036728332d3e3038047851aea7c6c75c89f14810ec1c54c03ab8f1864a4c4032791f05747f560faec380a695d1000000000000049a0000000000000008fffffffb00000000000005dc0000000000000003000000000100000001000000006329c0eb000000006329c0e9000000006329c0e400000000000006150000000000000007215258d81468614f6b7e194c5d145609394f67b041e93e6695dcc616faadd0603b9551a68d01d954d6387aff4df1529027ffb2fee413082e509feb29cc4904fe000000000000041a0000000000000003fffffffb00000000000005cb0000000000000003010000000100000001000000006329c0eb000000006329c0e9000000006329c0e4000000000000048600000000000000078ac9cf3ab299af710d735163726fdae0db8465280502eb9f801f74b3c1bd190333832fad6e36eb05a8972fe5f219b27b5b2bb2230a79ce79beb4c5c5e7ecc76d00000000000003f20000000000000002fffffffb00000000000005e70000000000000003010000000100000001000000006329c0eb000000006329c0e9000000006329c0e40000000000000685000000000000000861db714e9ff987b6fedf00d01f9fea6db7c30632d6fc83b7bc9459d7192bc44a21a28b4c6619968bd8c20e95b0aaed7df2187fd310275347e0376a2cd7427db800000000000006cb0000000000000001fffffffb00000000000005e40000000000000003010000000100000001000000006329c0eb000000006329c0e9000000006329c0e400000000000007970000000000000001",
    ];
    let mut verified_vaas_reversed = vector::empty<VAA>();
    let mut test_vaas = test_vaas_;
    let mut i = 0;
    while (i < vector::length(&test_vaas_)) {
        let cur_test_vaa = vector::pop_back(&mut test_vaas);
        let verified_vaa = vaa::parse_and_verify(worm_state, cur_test_vaa, clock);
        vector::push_back(&mut verified_vaas_reversed, verified_vaa);
        i = i+1;
    };
    let mut verified_vaas = vector::empty<VAA>();
    while (vector::length<VAA>(&verified_vaas_reversed)!=0) {
        let cur = vector::pop_back(&mut verified_vaas_reversed);
        vector::push_back(&mut verified_vaas, cur);
    };
    vector::destroy_empty(verified_vaas_reversed);
    verified_vaas
}

// get_verified_vaa_from_accumulator_message parses the accumulator message up until the vaa, then
// parses the vaa, yielding a verified wormhole::vaa::VAA object
fun get_verified_vaa_from_accumulator_message(
    worm_state: &WormState,
    accumulator_message: vector<u8>,
    clock: &Clock,
): VAA {
    let _PYTHNET_ACCUMULATOR_UPDATE_MAGIC: u64 = 1347305813;

    let mut cursor = cursor::new(accumulator_message);
    let header: u32 = deserialize::deserialize_u32(&mut cursor);
    assert!((header as u64) == _PYTHNET_ACCUMULATOR_UPDATE_MAGIC, 0);
    let _major = deserialize::deserialize_u8(&mut cursor);
    let _minor = deserialize::deserialize_u8(&mut cursor);

    let trailing_size = deserialize::deserialize_u8(&mut cursor);
    deserialize::deserialize_vector(&mut cursor, (trailing_size as u64));

    let proof_type = deserialize::deserialize_u8(&mut cursor);
    assert!(proof_type == 0, 0);

    let vaa_size = deserialize::deserialize_u16(&mut cursor);
    let vaa = deserialize::deserialize_vector(&mut cursor, (vaa_size as u64));
    cursor::take_rest(cursor);
    vaa::parse_and_verify(worm_state, vaa, clock)
}

#[test_only]
/// Init Wormhole core bridge state.
/// Init Pyth state.
/// Set initial Sui clock time.
/// Mint some SUI fee coins.
public fun setup_test(
    stale_price_threshold: u64,
    governance_emitter_chain_id: u64,
    governance_emitter_address: vector<u8>,
    data_sources: vector<DataSource>,
    initial_guardians: vector<vector<u8>>,
    base_update_fee: u64,
    to_mint: u64,
): (Scenario, Coin<SUI>, Clock) {
    let mut scenario = test_scenario::begin(DEPLOYER);

    // Initialize Wormhole core bridge.
    wormhole_setup::init_test_only(ctx(&mut scenario));
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    // Take the `DeployerCap` from the sender of the transaction.
    let deployer_cap = test_scenario::take_from_address<DeployerCap>(
        &scenario,
        DEPLOYER,
    );

    // This will be created and sent to the transaction sender automatically
    // when the contract is published. This exists in place of grabbing
    // it from the sender.
    let upgrade_cap = package::test_publish(
        object::id_from_address(@wormhole),
        test_scenario::ctx(&mut scenario),
    );

    let governance_chain = 1234;
    let governance_contract = x"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
    let guardian_set_seconds_to_live = 5678;
    let message_fee = 350;
    let guardian_set_index = 0;
    wormhole_setup::complete(
        deployer_cap,
        upgrade_cap,
        governance_chain,
        governance_contract,
        guardian_set_index,
        initial_guardians,
        guardian_set_seconds_to_live,
        message_fee,
        test_scenario::ctx(&mut scenario),
    );

    // Initialize Pyth state.
    let pyth_upgrade_cap = package::test_publish(
        object::id_from_address(@pyth),
        test_scenario::ctx(&mut scenario),
    );

    setup::init_test_only(ctx(&mut scenario));
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    let pyth_deployer_cap = test_scenario::take_from_address<setup::DeployerCap>(
        &scenario,
        DEPLOYER,
    );

    setup::init_and_share_state(
        pyth_deployer_cap,
        pyth_upgrade_cap,
        stale_price_threshold,
        base_update_fee,
        data_source::new(
            governance_emitter_chain_id,
            external_address::new(bytes32::from_bytes(governance_emitter_address)),
        ),
        data_sources,
        ctx(&mut scenario),
    );

    let coins = coin::mint_for_testing<SUI>(to_mint, ctx(&mut scenario));
    let clock = clock::create_for_testing(ctx(&mut scenario));
    (scenario, coins, clock)
}

fun get_mock_price_infos(): vector<PriceInfo> {
    use pyth::i64::Self;
    use pyth::price;
    vector<PriceInfo>[
        price_info::new_price_info(
            1663680747,
            1663074349,
            price_feed::new(
                price_identifier::from_byte_vec(
                    x"c6c75c89f14810ec1c54c03ab8f1864a4c4032791f05747f560faec380a695d1",
                ),
                price::new(i64::new(1557, false), 7, i64::new(5, true), 1663680740),
                price::new(i64::new(1500, false), 3, i64::new(5, true), 1663680740),
            ),
        ),
        price_info::new_price_info(
            1663680747,
            1663074349,
            price_feed::new(
                price_identifier::from_byte_vec(
                    x"3b9551a68d01d954d6387aff4df1529027ffb2fee413082e509feb29cc4904fe",
                ),
                price::new(i64::new(1050, false), 3, i64::new(5, true), 1663680745),
                price::new(i64::new(1483, false), 3, i64::new(5, true), 1663680745),
            ),
        ),
        price_info::new_price_info(
            1663680747,
            1663074349,
            price_feed::new(
                price_identifier::from_byte_vec(
                    x"33832fad6e36eb05a8972fe5f219b27b5b2bb2230a79ce79beb4c5c5e7ecc76d",
                ),
                price::new(i64::new(1010, false), 2, i64::new(5, true), 1663680745),
                price::new(i64::new(1511, false), 3, i64::new(5, true), 1663680745),
            ),
        ),
        price_info::new_price_info(
            1663680747,
            1663074349,
            price_feed::new(
                price_identifier::from_byte_vec(
                    x"21a28b4c6619968bd8c20e95b0aaed7df2187fd310275347e0376a2cd7427db8",
                ),
                price::new(i64::new(1739, false), 1, i64::new(5, true), 1663680745),
                price::new(i64::new(1508, false), 3, i64::new(5, true), 1663680745),
            ),
        ),
    ]
}

/// Compare the expected price feed with the actual Pyth price feeds.
fun check_price_feeds_cached(expected: &vector<PriceInfo>, actual: &vector<PriceInfoObject>) {
    // Check that we can retrieve the correct current price and ema price for each price feed
    let mut i = 0;
    while (i < vector::length(expected)) {
        let price_feed = price_info::get_price_feed(vector::borrow(expected, i));
        let price = price_feed::get_price(price_feed);
        let ema_price = price_feed::get_ema_price(price_feed);
        let price_identifier = price_info::get_price_identifier(vector::borrow(expected, i));

        let actual_price_info = price_info::get_price_info_from_price_info_object(
            vector::borrow(actual, i),
        );
        let actual_price_feed = price_info::get_price_feed(&actual_price_info);
        let actual_price = price_feed::get_price(actual_price_feed);
        let actual_ema_price = price_feed::get_ema_price(actual_price_feed);
        let actual_price_identifier = price_info::get_price_identifier(&actual_price_info);

        assert!(price == actual_price, 0);
        assert!(ema_price == actual_ema_price, 0);
        assert!(
            price_identifier::get_bytes(&price_identifier) == price_identifier::get_bytes(&actual_price_identifier),
            0,
        );

        i = i + 1;
    };
}

#[test]
fun test_get_update_fee() {
    let (mut scenario, test_coins, _clock) = setup_test(
        500,
        /* stale_price_threshold */
        23,
        /* governance emitter chain */
        x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
        vector[],
        BATCH_ATTESTATION_TEST_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        0,
    );
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    let pyth_state = take_shared<PythState>(&scenario);
    // Pass in a single VAA

    let single_vaa = vector[x"fb1543888001083cf2e6ef3afdcf827e89b11efd87c563638df6e1995ada9f93"];

    assert!(
        pyth::get_total_update_fee(&pyth_state, vector::length<vector<u8>>(&single_vaa)) == DEFAULT_BASE_UPDATE_FEE,
        1,
    );

    let multiple_vaas = vector[
        x"4ee17a1a4524118de513fddcf82b77454e51be5d6fc9e29fc72dd6c204c0e4fa",
        x"c72fdf81cfc939d4286c93fbaaae2eec7bae28a5926fa68646b43a279846ccc1",
        x"d9a8123a793529c31200339820a3210059ecace6c044f81ecad62936e47ca049",
        x"84e4f21b3e65cef47fda25d15b4eddda1edf720a1d062ccbf441d6396465fbe6",
        x"9e73f9041476a93701a0b9c7501422cc2aa55d16100bec628cf53e0281b6f72f",
    ];

    // Pass in multiple VAAs
    assert!(
        pyth::get_total_update_fee(&pyth_state, vector::length<vector<u8>>(&multiple_vaas)) == 5*DEFAULT_BASE_UPDATE_FEE,
        1,
    );

    return_shared(pyth_state);
    coin::burn_for_testing<SUI>(test_coins);
    clock::destroy_for_testing(_clock);
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = wormhole::vaa::E_WRONG_VERSION)]
fun test_create_price_feeds_corrupt_vaa() {
    let (mut scenario, test_coins, clock) = setup_test(
        500,
        /* stale_price_threshold */
        23,
        /* governance emitter chain */
        x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
        vector[],
        vector[x"beFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe"],
        50,
        0,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    // Pass in a corrupt VAA, which should fail deserializing
    let corrupt_vaa = x"90F8bf6A479f320ead074411a4B0e7944Ea8c9C1";
    let verified_vaas = vector[vaa::parse_and_verify(&worm_state, corrupt_vaa, &clock)];
    // Create Pyth price feed
    pyth::create_price_feeds(
        &mut pyth_state,
        verified_vaas,
        &clock,
        ctx(&mut scenario),
    );

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    coin::burn_for_testing<SUI>(test_coins);
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = ::pyth::pyth::EInvalidDataSource)]
fun test_create_price_feeds_invalid_data_source() {
    // Initialize the contract with some valid data sources, excluding our test VAA's source
    let data_sources = vector<DataSource>[
        data_source::new(
            4,
            external_address::new(
                bytes32::new(
                    x"0000000000000000000000000000000000000000000000000000000000007742",
                ),
            ),
        ),
        data_source::new(
            5,
            external_address::new(
                bytes32::new(
                    x"0000000000000000000000000000000000000000000000000000000000007637",
                ),
            ),
        ),
    ];
    let (mut scenario, test_coins, clock) = setup_test(
        500,
        23,
        x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
        data_sources,
        BATCH_ATTESTATION_TEST_INITIAL_GUARDIANS,
        50,
        0,
    );
    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let verified_vaas = get_verified_test_vaas(&worm_state, &clock);

    pyth::create_price_feeds(
        &mut pyth_state,
        verified_vaas,
        &clock,
        ctx(&mut scenario),
    );

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    coin::burn_for_testing<SUI>(test_coins);
    test_scenario::end(scenario);
}

public fun data_sources_for_test_vaa(): vector<DataSource> {
    // Set some valid data sources, including our test VAA's source
    vector<DataSource>[
        data_source::new(
            1,
            external_address::new(
                bytes32::from_bytes(
                    x"0000000000000000000000000000000000000000000000000000000000000004",
                ),
            ),
        ),
        data_source::new(
            5,
            external_address::new(
                bytes32::new(
                    x"0000000000000000000000000000000000000000000000000000000000007637",
                ),
            ),
        ),
        data_source::new(
            17,
            external_address::new(bytes32::new(ACCUMULATOR_TESTS_EMITTER_ADDRESS)),
        ),
    ]
}

#[test]
// test_create_and_update_price_feeds_with_batch_attestation_success tests the creation and updating of price
// feeds, as well as depositing fee coins into price info objects
fun test_create_and_update_price_feeds_with_batch_attestation_success() {
    let (mut scenario, mut test_coins, clock) = setup_test(
        500,
        23,
        x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
        data_sources_for_test_vaa(),
        vector[x"beFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe"],
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );
    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let mut verified_vaas = get_verified_test_vaas(&worm_state, &clock);

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds(
        &mut pyth_state,
        verified_vaas,
        &clock,
        ctx(&mut scenario),
    );

    // Affirm that 4 objects, which correspond to the 4 new price info objects
    // containing the price feeds were created and shared.
    let effects = test_scenario::next_tx(&mut scenario, DEPLOYER);
    let shared_ids = test_scenario::shared(&effects);
    let created_ids = test_scenario::created(&effects);
    assert!(vector::length<ID>(&shared_ids)==4, 0);
    assert!(vector::length<ID>(&created_ids)==4, 0);

    let mut price_info_object_1 = take_shared<PriceInfoObject>(&scenario);
    let price_info_object_2 = take_shared<PriceInfoObject>(&scenario);
    let price_info_object_3 = take_shared<PriceInfoObject>(&scenario);
    let price_info_object_4 = take_shared<PriceInfoObject>(&scenario);

    // Create vector of price info objects (Sui objects with key ability and living in global store),
    // which contain the price feeds we want to update. Note that these can be passed into
    // update_price_feeds in any order!
    //let price_info_object_vec = vector[price_info_object_1, price_info_object_2, price_info_object_3, price_info_object_4];
    verified_vaas = get_verified_test_vaas(&worm_state, &clock);
    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let vaa_1 = vector::pop_back<VAA>(&mut verified_vaas);

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    // Create authenticated price infos
    let mut vec = create_price_infos_hot_potato(
        &pyth_state,
        vector[vaa_1],
        &clock,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let fee_coins = coin::split(&mut test_coins, DEFAULT_BASE_UPDATE_FEE, ctx(&mut scenario));
    vec =
        update_single_price_feed(
            &pyth_state,
            vec,
            &mut price_info_object_1,
            fee_coins,
            &clock,
        );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    // check price feed updated
    assert!(
        price_feeds_equal(
            hot_potato_vector::borrow(&vec, 3),
            &price_info::get_price_info_from_price_info_object(&price_info_object_1),
        ),
        0,
    );

    // check fee coins are deposited in the price info object
    assert!(price_info::get_balance(&price_info_object_1)==DEFAULT_BASE_UPDATE_FEE, 0);

    test_scenario::next_tx(&mut scenario, DEPLOYER);
    hot_potato_vector::destroy<PriceInfo>(vec);

    vector::destroy_empty(verified_vaas);
    return_shared(price_info_object_1);
    return_shared(price_info_object_2);
    return_shared(price_info_object_3);
    return_shared(price_info_object_4);

    coin::burn_for_testing(test_coins);
    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

// TEST_ACCUMULATOR_SINGLE_FEED details:
//      Price Identifier: 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
//      Price: 6887568746747646632
//      Conf: 13092246197863718329
//      Exponent: 1559537863
//      EMA Price: 4772242609775910581
//      EMA Conf: 358129956189946877
//      EMA Expo: 1559537863
//      Published Time: 1687276661
const TEST_ACCUMULATOR_SINGLE_FEED: vector<u8> =
    x"504e41550100000000a0010000000001005d461ac1dfffa8451edda17e4b28a46c8ae912422b2dc0cb7732828c497778ea27147fb95b4d250651931845e7f3e22c46326716bcf82be2874a9c9ab94b6e42000000000000000000000171f8dcb863d176e2c420ad6610cf687359612b6fb392e0642b0ca6b1f186aa3b0000000000000000004155575600000000000000000000000000da936d73429246d131873a0bab90ad7b416510be01005500b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf65f958f4883f9d2a8b5b1008d1fa01db95cf4a8c7000000006491cc757be59f3f377c0d3f423a695e81ad1eb504f8554c3620c3fd02f2ee15ea639b73fa3db9b34a245bdfa015c260c5a8a1180177cf30b2c0bebbb1adfe8f7985d051d2";

#[test]
fun test_create_and_update_single_price_feed_with_accumulator_success() {
    let (mut scenario, coins, clock) = setup_test(
        500,
        23,
        ACCUMULATOR_TESTS_EMITTER_ADDRESS,
        ACCUMULATOR_TESTS_DATA_SOURCE(),
        ACCUMULATOR_TESTS_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let mut verified_vaa = get_verified_vaa_from_accumulator_message(
        &worm_state,
        TEST_ACCUMULATOR_SINGLE_FEED,
        &clock,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds_using_accumulator(
        &mut pyth_state,
        TEST_ACCUMULATOR_SINGLE_FEED,
        verified_vaa,
        &clock,
        ctx(&mut scenario),
    );

    // Affirm that 1 object, which correspond to the 1 new price info object
    // containing the price feeds were created and shared.
    let effects = test_scenario::next_tx(&mut scenario, DEPLOYER);
    let shared_ids = test_scenario::shared(&effects);
    let created_ids = test_scenario::created(&effects);
    assert!(vector::length<ID>(&shared_ids)==1, 0);
    assert!(vector::length<ID>(&created_ids)==1, 0);

    let mut price_info_object_1 = take_shared<PriceInfoObject>(&scenario);

    // Create authenticated price infos
    verified_vaa =
        get_verified_vaa_from_accumulator_message(
            &worm_state,
            TEST_ACCUMULATOR_SINGLE_FEED,
            &clock,
        );
    let mut auth_price_infos = pyth::create_authenticated_price_infos_using_accumulator(
        &pyth_state,
        TEST_ACCUMULATOR_SINGLE_FEED,
        verified_vaa,
        &clock,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);
    auth_price_infos =
        update_single_price_feed(
            &pyth_state,
            auth_price_infos,
            &mut price_info_object_1,
            coins,
            &clock,
        );

    // assert that price info obejct is as expected
    let expected = accumulator_test_1_to_price_info();
    assert!(
        price_feeds_equal(
            &expected,
            &price_info::get_price_info_from_price_info_object(&price_info_object_1),
        ),
        0,
    );

    // clean up test scenario

    test_scenario::next_tx(&mut scenario, DEPLOYER);
    hot_potato_vector::destroy<PriceInfo>(auth_price_infos);

    return_shared(price_info_object_1);

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = ::pyth::accumulator::EInvalidProof)]
fun test_create_and_update_single_price_feed_with_accumulator_failure() {
    let (mut scenario, coins, clock) = setup_test(
        500,
        23,
        ACCUMULATOR_TESTS_EMITTER_ADDRESS,
        ACCUMULATOR_TESTS_DATA_SOURCE(),
        ACCUMULATOR_TESTS_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    // the verified vaa here contains the wrong merkle root
    let verified_vaa = get_verified_vaa_from_accumulator_message(
        &worm_state,
        TEST_ACCUMULATOR_3_MSGS,
        &clock,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds_using_accumulator(
        &mut pyth_state,
        TEST_ACCUMULATOR_SINGLE_FEED,
        verified_vaa,
        &clock,
        ctx(&mut scenario),
    );

    // clean up test scenario
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    coin::burn_for_testing<SUI>(coins);

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

#[test_only]
const TEST_ACCUMULATOR_INVALID_PROOF_1: vector<u8> =
    x"504e41550100000000a001000000000100110db9cd8325ccfab0dae92eeb9ea70a1faba5c5e96dc21ff46a8ddc560afc9a60df096b8ff21172804692bbdc958153e838437d8b474cbf45f0dc2a8acae831000000000000000000000171f8dcb863d176e2c420ad6610cf687359612b6fb392e0642b0ca6b1f186aa3b0000000000000000004155575600000000000000000000000000a8bea2b5f12f3177ff9b3929d77c3476ab2d32c602005500b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6fa75cd3aa3bb5ace5e2516446f71f85be36bd19bb0703f3154bb3db07be59f3f377c0d3f44661d9a8736c68884c8169e8b636ee3043202397384073120dce9e5d0efe24b44b4a0d62da8a1180177cf30b2c0bebbb1adfe8f7985d051d205a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d950055006e1540171b6c0c960b71a7020d9f60077f6af931a8bbf590da0223dacf75c7af5f958f4883f9d2a8b5b1008d1fa01db95cf4a8c7423a695e81ad1eb504f8554c3620c3fd40b40f7d581ac802e2de5cb82a9ae672043202397384073120dce9e5d0efe24b44b4a0d62da8a1180177cf30b2c0bebbb1adfe8f7985d051d205a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d95";

#[test, expected_failure(abort_code = ::pyth::accumulator::EInvalidProof)]
fun test_accumulator_invalid_proof() {
    let (mut scenario, coins, clock) = setup_test(
        500,
        23,
        ACCUMULATOR_TESTS_EMITTER_ADDRESS,
        ACCUMULATOR_TESTS_DATA_SOURCE(),
        ACCUMULATOR_TESTS_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let verified_vaa = get_verified_vaa_from_accumulator_message(
        &worm_state,
        TEST_ACCUMULATOR_INVALID_PROOF_1,
        &clock,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds_using_accumulator(
        &mut pyth_state,
        TEST_ACCUMULATOR_INVALID_PROOF_1,
        verified_vaa,
        &clock,
        ctx(&mut scenario),
    );

    // clean up test scenario
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    coin::burn_for_testing<SUI>(coins);

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

#[test_only]
const TEST_ACCUMULATOR_INVALID_MAJOR_VERSION: vector<u8> =
    x"504e41553c00000000a001000000000100496b7fbd18dca2f0e690712fd8ca522ff79ca7d9d6d22e9f5d753fba4bd16fff440a811bad710071c79859290bcb1700de49dd8400db90b048437b521200123e010000000000000000000171f8dcb863d176e2c420ad6610cf687359612b6fb392e0642b0ca6b1f186aa3b000000000000000000415557560000000000000000000000000005f5db4488a7cae9f9a6c1938340c0fbf4beb9090200550031ecc21a745e3968a04e9570e4425bc18fa8019c68028196b546d1669c200c6879bc5a3617ec3444d93c06501cf6a0909c38d4ec81d96026b71ec475e87d69c7b5124289adbf24212bed8c15db354391d2378d2e0454d2655c6c34e7e50580fd8c94511322968bbc6da8a1180177cf30b2c0bebbb1adfe8f7985d051d205a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d95005500944998273e477b495144fb8794c914197f3ccb46be2900f4698fd0ef743c9695a573a6ff665ff63edb5f9a85ad579dc14500a2112c09680fc146134f9a539ca82cb6e3501c801278fd08d80732a24118292866bb049e6e88181a1e1e8b6d3c6bbb95135a73041f3b56a8a1180177cf30b2c0bebbb1adfe8f7985d051d205a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d95";

#[test, expected_failure(abort_code = ::pyth::accumulator::EInvalidAccumulatorPayload)]
fun test_accumulator_invalid_major_version() {
    let (mut scenario, coins, clock) = setup_test(
        500,
        23,
        ACCUMULATOR_TESTS_EMITTER_ADDRESS,
        ACCUMULATOR_TESTS_DATA_SOURCE(),
        ACCUMULATOR_TESTS_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let verified_vaa = get_verified_vaa_from_accumulator_message(
        &worm_state,
        TEST_ACCUMULATOR_INVALID_MAJOR_VERSION,
        &clock,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds_using_accumulator(
        &mut pyth_state,
        TEST_ACCUMULATOR_INVALID_MAJOR_VERSION,
        verified_vaa,
        &clock,
        ctx(&mut scenario),
    );

    // clean up test scenario
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    coin::burn_for_testing<SUI>(coins);

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

#[test_only]
const TEST_ACCUMULATOR_INVALID_WH_MSG: vector<u8> =
    x"504e41550100000000a001000000000100e87f98238c5357730936cfdfde3a37249e5219409a4f41b301924b8eb10815a43ea2f96e4fe1bc8cd398250f39448d3b8ca57c96f9cf7a2be292517280683caa010000000000000000000171f8dcb863d176e2c420ad6610cf687359612b6fb392e0642b0ca6b1f186aa3b00000000000000000041555755000000000000000000000000000fb6f9f2b3b6cc1c9ef6708985fef226d92a3c0801005500b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6fa75cd3aa3bb5ace5e2516446f71f85be36bd19b000000006491cc747be59f3f377c0d3f44661d9a8736c68884c8169e8b636ee301f2ee15ea639b73fa3db9b34a245bdfa015c260c5";

#[test, expected_failure(abort_code = ::pyth::accumulator::EInvalidWormholeMessage)]
fun test_accumulator_invalid_wormhole_message() {
    let (mut scenario, coins, clock) = setup_test(
        500,
        23,
        ACCUMULATOR_TESTS_EMITTER_ADDRESS,
        ACCUMULATOR_TESTS_DATA_SOURCE(),
        ACCUMULATOR_TESTS_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let verified_vaa = get_verified_vaa_from_accumulator_message(
        &worm_state,
        TEST_ACCUMULATOR_INVALID_WH_MSG,
        &clock,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds_using_accumulator(
        &mut pyth_state,
        TEST_ACCUMULATOR_INVALID_WH_MSG,
        verified_vaa,
        &clock,
        ctx(&mut scenario),
    );

    // clean up test scenario
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    coin::burn_for_testing<SUI>(coins);

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

#[test_only]
const TEST_ACCUMULATOR_INCREASED_MINOR_VERSION: vector<u8> =
    x"504e4155010a000000a001000000000100496b7fbd18dca2f0e690712fd8ca522ff79ca7d9d6d22e9f5d753fba4bd16fff440a811bad710071c79859290bcb1700de49dd8400db90b048437b521200123e010000000000000000000171f8dcb863d176e2c420ad6610cf687359612b6fb392e0642b0ca6b1f186aa3b000000000000000000415557560000000000000000000000000005f5db4488a7cae9f9a6c1938340c0fbf4beb9090200550031ecc21a745e3968a04e9570e4425bc18fa8019c68028196b546d1669c200c6879bc5a3617ec3444d93c06501cf6a0909c38d4ec81d96026b71ec475e87d69c7b5124289adbf24212bed8c15db354391d2378d2e0454d2655c6c34e7e50580fd8c94511322968bbc6da8a1180177cf30b2c0bebbb1adfe8f7985d051d205a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d95005500944998273e477b495144fb8794c914197f3ccb46be2900f4698fd0ef743c9695a573a6ff665ff63edb5f9a85ad579dc14500a2112c09680fc146134f9a539ca82cb6e3501c801278fd08d80732a24118292866bb049e6e88181a1e1e8b6d3c6bbb95135a73041f3b56a8a1180177cf30b2c0bebbb1adfe8f7985d051d205a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d95";
#[test_only]
const TEST_ACCUMULATOR_EXTRA_PAYLOAD: vector<u8> =
    x"504e41550100000000a001000000000100b2d11f181d81b4ff10beca30091754b464dc48bc1f7432d114f64a7a8f660e7964f2a0c6121bae6c1977514d46ee7a29d9395b20a45f2086071715c1dc19ab74000000000000000000000171f8dcb863d176e2c420ad6610cf687359612b6fb392e0642b0ca6b1f186aa3b000000000000000000415557560000000000000000000000000013f83cfdf63a5a1b3189182fa0a52e6de53ba7d002005d0031ecc21a745e3968a04e9570e4425bc18fa8019c68028196b546d1669c200c6879bc5a3617ec3444d93c06501cf6a0909c38d4ec81d96026b71ec475e87d69c7b5124289adbf24212bed8c15db354391d2378d2e000000000000000004a576f4a87f443f7d961a682f508c4f7b06ee1595a8a1180177cf30b2c0bebbb1adfe8f7985d051d205a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d95005d00944998273e477b495144fb8794c914197f3ccb46be2900f4698fd0ef743c9695a573a6ff665ff63edb5f9a85ad579dc14500a2112c09680fc146134f9a539ca82cb6e3501c801278fd08d80732a24118292866bb0000000000000000045be67ba87a8dfbea404827ccbf07790299b6c023a8a1180177cf30b2c0bebbb1adfe8f7985d051d205a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d95";

#[test]
fun test_accumulator_forward_compatibility() {
    let (mut scenario, coins, clock) = setup_test(
        500,
        23,
        ACCUMULATOR_TESTS_EMITTER_ADDRESS,
        ACCUMULATOR_TESTS_DATA_SOURCE(),
        ACCUMULATOR_TESTS_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds_using_accumulator(
        &mut pyth_state,
        TEST_ACCUMULATOR_EXTRA_PAYLOAD,
        get_verified_vaa_from_accumulator_message(
            &worm_state,
            TEST_ACCUMULATOR_EXTRA_PAYLOAD,
            &clock,
        ),
        &clock,
        ctx(&mut scenario),
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds_using_accumulator(
        &mut pyth_state,
        TEST_ACCUMULATOR_INCREASED_MINOR_VERSION,
        get_verified_vaa_from_accumulator_message(
            &worm_state,
            TEST_ACCUMULATOR_INCREASED_MINOR_VERSION,
            &clock,
        ),
        &clock,
        ctx(&mut scenario),
    );

    // clean up test scenario
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    coin::burn_for_testing<SUI>(coins);

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

// TEST_ACCUMULATOR_3_MSGS details:
//      Price Identifier: 0xb10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6
//      Price: 100
//      Conf: 50
//      Exponent: 9
//      EMA Price: 99
//      EMA Conf: 52
//      EMA Expo: 9
//      Published Time: 1687276660

//      Price Identifier: 0x6e1540171b6c0c960b71a7020d9f60077f6af931a8bbf590da0223dacf75c7af
//      Price: 101
//      Conf: 51
//      Exponent: 10
//      EMA Price: 100
//      EMA Conf: 53
//      EMA Expo: 10
//      Published Time: 1687276661

//      Price Identifier: 0x31ecc21a745e3968a04e9570e4425bc18fa8019c68028196b546d1669c200c68
//      Price: 102
//      Conf: 52
//      Exponent: 11
//      EMA Price: 101
//      EMA Conf: 54
//      EMA Expo: 11
//      Published Time: 1687276662
const TEST_ACCUMULATOR_3_MSGS: vector<u8> =
    x"504e41550100000000a001000000000100d39b55fa311213959f91866d52624f3a9c07350d8956f6d42cfbb037883f31575c494a2f09fea84e4884dc9c244123fd124bc7825cd64d7c11e33ba5cfbdea7e010000000000000000000171f8dcb863d176e2c420ad6610cf687359612b6fb392e0642b0ca6b1f186aa3b000000000000000000415557560000000000000000000000000029da4c066b6e03b16a71e77811570dd9e19f258103005500b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf60000000000000064000000000000003200000009000000006491cc747be59f3f377c0d3f000000000000006300000000000000340436992facb15658a7e9f08c4df4848ca80750f61fadcd96993de66b1fe7aef94e29e3bbef8b12db2305a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d950055006e1540171b6c0c960b71a7020d9f60077f6af931a8bbf590da0223dacf75c7af000000000000006500000000000000330000000a000000006491cc7504f8554c3620c3fd0000000000000064000000000000003504171ed10ac4f1eacf3a4951e1da6b119f07c45da5adcd96993de66b1fe7aef94e29e3bbef8b12db2305a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d9500550031ecc21a745e3968a04e9570e4425bc18fa8019c68028196b546d1669c200c68000000000000006600000000000000340000000b000000006491cc76e87d69c7b51242890000000000000065000000000000003604f2ee15ea639b73fa3db9b34a245bdfa015c260c5fe83e4772e0e346613de00e5348158a01bcb27b305a01e2504d9f0c06e7e7cb0cf24116098ca202ac5f6ade2e8f5a12ec006b16d46be1f0228b94d95";

#[test]
fun test_create_and_update_multiple_price_feeds_with_accumulator_success() {
    let (mut scenario, mut coins, clock) = setup_test(
        500,
        23,
        ACCUMULATOR_TESTS_EMITTER_ADDRESS,
        ACCUMULATOR_TESTS_DATA_SOURCE(),
        ACCUMULATOR_TESTS_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let mut verified_vaa = get_verified_vaa_from_accumulator_message(
        &worm_state,
        TEST_ACCUMULATOR_3_MSGS,
        &clock,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds_using_accumulator(
        &mut pyth_state,
        TEST_ACCUMULATOR_3_MSGS,
        verified_vaa,
        &clock,
        ctx(&mut scenario),
    );

    // Affirm that 3 objects, which correspond to the 3 new price info objects
    // containing the price feeds were created and shared.
    let effects = test_scenario::next_tx(&mut scenario, DEPLOYER);
    let shared_ids = test_scenario::shared(&effects);
    let created_ids = test_scenario::created(&effects);
    assert!(vector::length<ID>(&shared_ids)==3, 0);
    assert!(vector::length<ID>(&created_ids)==3, 0);

    // Create authenticated price infos
    verified_vaa =
        get_verified_vaa_from_accumulator_message(&worm_state, TEST_ACCUMULATOR_3_MSGS, &clock);
    let mut auth_price_infos = pyth::create_authenticated_price_infos_using_accumulator(
        &pyth_state,
        TEST_ACCUMULATOR_3_MSGS,
        verified_vaa,
        &clock,
    );

    let mut idx = 0;
    let expected_price_infos = accumulator_test_3_to_price_info(0 /*offset argument*/);

    while (idx < 3) {
        let coin_split = coin::split(&mut coins, 1000, ctx(&mut scenario));
        let mut price_info_object = take_shared<PriceInfoObject>(&scenario);
        auth_price_infos =
            update_single_price_feed(
                &pyth_state,
                auth_price_infos,
                &mut price_info_object,
                coin_split,
                &clock,
            );
        let price_info = price_info::get_price_info_from_price_info_object(&price_info_object);
        assert!(price_feeds_equal(&price_info, vector::borrow(&expected_price_infos, idx)), 0);
        return_shared(price_info_object);
        idx = idx + 1;
    };
    coin::burn_for_testing<SUI>(coins);

    // clean up test scenario
    test_scenario::next_tx(&mut scenario, DEPLOYER);
    hot_potato_vector::destroy<PriceInfo>(auth_price_infos);

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

#[test, expected_failure(abort_code = ::pyth::pyth::EInsufficientFee)]
fun test_create_and_update_price_feeds_insufficient_fee() {
    // this is not enough fee and will cause a failure
    let coins_to_mint = 1;

    let (mut scenario, test_coins, clock) = setup_test(
        500,
        23,
        x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
        data_sources_for_test_vaa(),
        vector[x"beFA429d57cD18b7F8A4d91A2da9AB4AF05d0FBe"],
        DEFAULT_BASE_UPDATE_FEE,
        coins_to_mint,
    );
    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let mut verified_vaas = get_verified_test_vaas(&worm_state, &clock);

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    pyth::create_price_feeds(
        &mut pyth_state,
        verified_vaas,
        &clock,
        ctx(&mut scenario),
    );

    // Affirm that 4 objects, which correspond to the 4 new price info objects
    // containing the price feeds were created and shared.
    let effects = test_scenario::next_tx(&mut scenario, DEPLOYER);
    let shared_ids = test_scenario::shared(&effects);
    let created_ids = test_scenario::created(&effects);
    assert!(vector::length<ID>(&shared_ids)==4, 0);
    assert!(vector::length<ID>(&created_ids)==4, 0);

    let mut price_info_object_1 = take_shared<PriceInfoObject>(&scenario);
    let price_info_object_2 = take_shared<PriceInfoObject>(&scenario);
    let price_info_object_3 = take_shared<PriceInfoObject>(&scenario);
    let price_info_object_4 = take_shared<PriceInfoObject>(&scenario);

    // Create vector of price info objects (Sui objects with key ability and living in global store),
    // which contain the price feeds we want to update. Note that these can be passed into
    // update_price_feeds in any order!
    //let price_info_object_vec = vector[price_info_object_1, price_info_object_2, price_info_object_3, price_info_object_4];
    verified_vaas = get_verified_test_vaas(&worm_state, &clock);
    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let vaa_1 = vector::pop_back<VAA>(&mut verified_vaas);

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    // Create authenticated price infos
    let mut vec = create_price_infos_hot_potato(
        &pyth_state,
        vector[vaa_1],
        &clock,
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);
    vec =
        update_single_price_feed(
            &pyth_state,
            vec,
            &mut price_info_object_1,
            test_coins,
            &clock,
        );

    test_scenario::next_tx(&mut scenario, DEPLOYER);
    hot_potato_vector::destroy<PriceInfo>(vec);

    vector::destroy_empty(verified_vaas);

    return_shared(price_info_object_1);
    return_shared(price_info_object_2);
    return_shared(price_info_object_3);
    return_shared(price_info_object_4);

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

#[test]
fun test_update_cache() {
    let (mut scenario, test_coins, clock) = setup_test(
        500,
        23,
        x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
        data_sources_for_test_vaa(),
        BATCH_ATTESTATION_TEST_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );
    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);

    let verified_vaas = get_verified_test_vaas(&worm_state, &clock);

    // Update cache is called by create_price_feeds.
    pyth::create_price_feeds(
        &mut pyth_state,
        verified_vaas,
        &clock,
        ctx(&mut scenario),
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let mut price_info_object_1 = take_shared<PriceInfoObject>(&scenario);
    let mut price_info_object_2 = take_shared<PriceInfoObject>(&scenario);
    let mut price_info_object_3 = take_shared<PriceInfoObject>(&scenario);
    let mut price_info_object_4 = take_shared<PriceInfoObject>(&scenario);

    // These updates are price infos that correspond to the ones in TEST_VAAS.
    let updates = get_mock_price_infos();
    let mut price_info_object_vec = vector[
        price_info_object_1,
        price_info_object_2,
        price_info_object_3,
        price_info_object_4,
    ];

    // Check that TEST_VAAS was indeed used to instantiate the price feeds correctly,
    // by confirming that the info in updates is contained in price_info_object_vec.
    check_price_feeds_cached(&updates, &price_info_object_vec);

    price_info_object_4 = vector::pop_back(&mut price_info_object_vec);
    price_info_object_3 = vector::pop_back(&mut price_info_object_vec);
    price_info_object_2 = vector::pop_back(&mut price_info_object_vec);
    price_info_object_1 = vector::pop_back(&mut price_info_object_vec);
    vector::destroy_empty(price_info_object_vec);

    return_shared(price_info_object_1);
    return_shared(price_info_object_2);
    return_shared(price_info_object_3);
    return_shared(price_info_object_4);
    coin::burn_for_testing<SUI>(test_coins);

    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

#[test]
fun test_update_cache_old_update() {
    use pyth::i64::Self;
    use pyth::price::Self;

    let (mut scenario, test_coins, clock) = setup_test(
        500,
        23,
        x"5d1f252d5de865279b00c84bce362774c2804294ed53299bc4a0389a5defef92",
        data_sources_for_test_vaa(),
        BATCH_ATTESTATION_TEST_INITIAL_GUARDIANS,
        DEFAULT_BASE_UPDATE_FEE,
        DEFAULT_COIN_TO_MINT,
    );
    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let (mut pyth_state, worm_state) = take_wormhole_and_pyth_states(&scenario);
    let verified_vaas = get_verified_test_vaas(&worm_state, &clock);

    pyth::create_price_feeds(
        &mut pyth_state,
        verified_vaas,
        &clock,
        ctx(&mut scenario),
    );

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    let mut price_info_object_1 = take_shared<PriceInfoObject>(&scenario);
    let price_info_object_2 = take_shared<PriceInfoObject>(&scenario);
    let price_info_object_3 = take_shared<PriceInfoObject>(&scenario);
    let price_info_object_4 = take_shared<PriceInfoObject>(&scenario);

    // Hardcode the price identifier, price, and ema_price for price_info_object_1, because
    // it's easier than unwrapping price_info_object_1 and getting the quantities via getters.
    let timestamp = 1663680740;
    let price_identifier = price_identifier::from_byte_vec(
        x"c6c75c89f14810ec1c54c03ab8f1864a4c4032791f05747f560faec380a695d1",
    );
    let price = price::new(i64::new(1557, false), 7, i64::new(5, true), timestamp);
    let ema_price = price::new(i64::new(1500, false), 3, i64::new(5, true), timestamp);

    // Attempt to update the price with an update older than the current cached one.
    let old_price = price::new(i64::new(1243, true), 9802, i64::new(6, false), timestamp - 200);
    let old_ema_price = price::new(
        i64::new(8976, true),
        234,
        i64::new(897, false),
        timestamp - 200,
    );
    let old_update = price_info::new_price_info(
        1257278600,
        1690226180,
        price_feed::new(
            price_identifier,
            old_price,
            old_ema_price,
        ),
    );
    let latest_only = ::pyth::state::create_latest_only_for_test();
    pyth::update_cache(latest_only, &old_update, &mut price_info_object_1, &clock);

    let current_price_info = price_info::get_price_info_from_price_info_object(
        &price_info_object_1,
    );
    let current_price_feed = price_info::get_price_feed(&current_price_info);
    let current_price = price_feed::get_price(current_price_feed);
    let current_ema_price = price_feed::get_ema_price(current_price_feed);

    // Confirm that no price update occurred when we tried to update cache with an
    // outdated update: old_update.
    assert!(current_price == price, 1);
    assert!(current_ema_price == ema_price, 1);

    test_scenario::next_tx(&mut scenario, DEPLOYER);

    // Update the cache with a fresh update.
    let fresh_price = price::new(i64::new(5243, true), 2, i64::new(3, false), timestamp + 200);
    let fresh_ema_price = price::new(
        i64::new(8976, true),
        21,
        i64::new(32, false),
        timestamp + 200,
    );
    let fresh_update = price_info::new_price_info(
        1257278600,
        1690226180,
        price_feed::new(
            price_identifier,
            fresh_price,
            fresh_ema_price,
        ),
    );

    let latest_only = ::pyth::state::create_latest_only_for_test();
    pyth::update_cache(latest_only, &fresh_update, &mut price_info_object_1, &clock);

    // Confirm that the Pyth cached price got updated to fresh_price.
    let current_price_info = price_info::get_price_info_from_price_info_object(
        &price_info_object_1,
    );
    let current_price_feed = price_info::get_price_feed(&current_price_info);
    let current_price = price_feed::get_price(current_price_feed);
    let current_ema_price = price_feed::get_ema_price(current_price_feed);

    assert!(current_price==fresh_price, 0);
    assert!(current_ema_price==fresh_ema_price, 0);

    return_shared(price_info_object_1);
    return_shared(price_info_object_2);
    return_shared(price_info_object_3);
    return_shared(price_info_object_4);

    coin::burn_for_testing<SUI>(test_coins);
    cleanup_worm_state_pyth_state_and_clock(worm_state, pyth_state, clock);
    test_scenario::end(scenario);
}

// pyth accumulator tests (included in this file instead of pyth_accumulator.move to avoid dependency cycle - as we need pyth_tests::setup_test)
#[test]
fun test_parse_and_verify_accumulator_updates() {
    let (mut scenario, coins, clock) = setup_test(
        500,
        23,
        ACCUMULATOR_TESTS_EMITTER_ADDRESS,
        vector[],
        ACCUMULATOR_TESTS_INITIAL_GUARDIANS,
        50,
        0,
    );
    let worm_state = take_shared<WormState>(&scenario);
    test_scenario::next_tx(&mut scenario, @0x123);

    let verified_vaa = get_verified_vaa_from_accumulator_message(
        &worm_state,
        TEST_ACCUMULATOR_3_MSGS,
        &clock,
    );

    let mut cur = cursor::new(TEST_ACCUMULATOR_3_MSGS);

    let price_info_updates = accumulator::parse_and_verify_accumulator_message(
        &mut cur,
        vaa::take_payload(verified_vaa),
        &clock,
    );

    let expected_price_infos = accumulator_test_3_to_price_info(0);
    let num_updates = vector::length<PriceInfo>(&price_info_updates);
    let mut i = 0;
    while (i < num_updates) {
        assert!(
            price_feeds_equal(
                vector::borrow(&price_info_updates, i),
                vector::borrow(&expected_price_infos, i),
            ),
            0,
        );
        i = i + 1;
    };

    // clean-up
    cursor::take_rest(cur);
    transfer::public_transfer(coins, @0x1234);
    clock::destroy_for_testing(clock);
    return_shared(worm_state);
    test_scenario::end(scenario);
}

#[test]
fun test_parse_and_verify_accumulator_updates_with_extra_bytes_at_end_of_message() {
    let (mut scenario, coins, clock) = setup_test(
        500,
        23,
        ACCUMULATOR_TESTS_EMITTER_ADDRESS,
        vector[],
        ACCUMULATOR_TESTS_INITIAL_GUARDIANS,
        50,
        0,
    );
    let worm_state = take_shared<WormState>(&scenario);
    test_scenario::next_tx(&mut scenario, @0x123);

    let verified_vaa = get_verified_vaa_from_accumulator_message(
        &worm_state,
        TEST_ACCUMULATOR_3_MSGS,
        &clock,
    );

    // append some extra garbage bytes at the end of the accumulator message, and make sure
    // that parse_and_verify_accumulator_message does not error out
    let mut test_accumulator_3_msgs_modified = TEST_ACCUMULATOR_3_MSGS;
    vector::append(&mut test_accumulator_3_msgs_modified, x"1234123412341234");

    let mut cur = cursor::new(TEST_ACCUMULATOR_3_MSGS);

    let price_info_updates = accumulator::parse_and_verify_accumulator_message(
        &mut cur,
        vaa::take_payload(verified_vaa),
        &clock,
    );

    let expected_price_infos = accumulator_test_3_to_price_info(0);
    let num_updates = vector::length<PriceInfo>(&price_info_updates);
    let mut i = 0;
    while (i < num_updates) {
        assert!(
            price_feeds_equal(
                vector::borrow(&price_info_updates, i),
                vector::borrow(&expected_price_infos, i),
            ),
            0,
        );
        i = i + 1;
    };

    // clean-up
    cursor::take_rest(cur);
    transfer::public_transfer(coins, @0x1234);
    clock::destroy_for_testing(clock);
    return_shared(worm_state);
    test_scenario::end(scenario);
}

fun price_feeds_equal(p1: &PriceInfo, p2: &PriceInfo): bool {
    price_info::get_price_feed(p1)== price_info::get_price_feed(p2)
}

// helper functions for setting up tests

// accumulator_test_3_to_price_info gets the data encoded within TEST_ACCUMULATOR_3_MSGS
fun accumulator_test_3_to_price_info(offset: u64): vector<PriceInfo> {
    use pyth::i64;
    use pyth::price;
    let mut i = 0;
    let feed_ids = vector[
        x"b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6",
        x"6e1540171b6c0c960b71a7020d9f60077f6af931a8bbf590da0223dacf75c7af",
        x"31ecc21a745e3968a04e9570e4425bc18fa8019c68028196b546d1669c200c68",
    ];
    let mut expected: vector<PriceInfo> = vector[];
    while (i < 3) {
        vector::push_back(
            &mut expected,
            price_info::new_price_info(
                1663680747,
                1663074349,
                price_feed::new(
                    price_identifier::from_byte_vec(
                        *vector::borrow(&feed_ids, i),
                    ),
                    price::new(
                        i64::new(100 + i + offset, false),
                        50 + i + offset,
                        i64::new(9 + i + offset, false),
                        1687276660 + i + offset,
                    ),
                    price::new(
                        i64::new(99 + i + offset, false),
                        52 + i + offset,
                        i64::new(9 + i + offset, false),
                        1687276660 + i + offset,
                    ),
                ),
            ),
        );
        i = i + 1;
    };
    return expected
}

// accumulator_test_1_to_price_info gets the data encoded within TEST_ACCUMULATOR_SINGLE_FEED
fun accumulator_test_1_to_price_info(): PriceInfo {
    use pyth::i64;
    use pyth::price;
    price_info::new_price_info(
        1663680747,
        1663074349,
        price_feed::new(
            price_identifier::from_byte_vec(
                x"b10e2d527612073b26eecdfd717e6a320cf44b4afac2b0732d9fcbe2b7fa0cf6",
            ),
            price::new(
                i64::new(6887568746747646632, false),
                13092246197863718329,
                i64::new(1559537863, false),
                1687276661,
            ),
            price::new(
                i64::new(4772242609775910581, false),
                358129956189946877,
                i64::new(1559537863, false),
                1687276661,
            ),
        ),
    )
}

public fun cleanup_worm_state_pyth_state_and_clock(
    worm_state: WormState,
    pyth_state: PythState,
    clock: Clock,
) {
    return_shared(worm_state);
    return_shared(pyth_state);
    clock::destroy_for_testing(clock);
}

public fun take_wormhole_and_pyth_states(scenario: &Scenario): (PythState, WormState) {
    (take_shared<PythState>(scenario), take_shared<WormState>(scenario))
}
