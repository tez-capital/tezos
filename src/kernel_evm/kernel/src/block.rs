// SPDX-FileCopyrightText: 2023 Nomadic Labs <contact@nomadic-labs.com>
// SPDX-FileCopyrightText: 2023 Functori <contact@functori.com>
// SPDX-FileCopyrightText: 2023 Marigold <contact@marigold.dev>
//
// SPDX-License-Identifier: MIT

use crate::apply::apply_transaction;
use crate::block_in_progress;
use crate::blueprint::Queue;
use crate::current_timestamp;
use crate::error::Error;
use crate::indexable_storage::IndexableStorage;
use crate::storage;
use crate::storage::init_account_index;
use crate::tick_model;
use anyhow::Context;
use block_in_progress::BlockInProgress;
use evm_execution::account_storage::{init_account_storage, EthereumAccountStorage};
use evm_execution::precompiles;
use evm_execution::precompiles::PrecompileBTreeMap;
use primitive_types::U256;
use tezos_evm_logging::{log, Level::*};
use tezos_smart_rollup_host::runtime::Runtime;

use tezos_ethereum::block::BlockConstants;

/// Struct used to allow the compiler to check that the tick counter value is
/// correctly moved and updated. Copy and Clone should NOT be derived.
struct TickCounter {
    c: u64,
}

impl TickCounter {
    pub fn new(c: u64) -> Self {
        Self { c }
    }
}

pub enum ComputationResult {
    RebootNeeded,
    Finished,
}

fn compute<Host: Runtime>(
    host: &mut Host,
    block_in_progress: &mut BlockInProgress,
    block_constants: &BlockConstants,
    precompiles: &PrecompileBTreeMap<Host>,
    evm_account_storage: &mut EthereumAccountStorage,
    accounts_index: &mut IndexableStorage,
) -> Result<ComputationResult, anyhow::Error> {
    // iteration over all remaining transaction in the block
    while block_in_progress.has_tx() {
        // is reboot necessary ?
        if block_in_progress.would_overflow() {
            // TODO: https://gitlab.com/tezos/tezos/-/issues/6094
            // there should be an upper bound on gasLimit
            return Ok(ComputationResult::RebootNeeded);
        }
        let transaction = block_in_progress.pop_tx().ok_or(Error::Reboot)?;

        // If `apply_transaction` returns `None`, the transaction should be
        // ignored, i.e. invalid signature or nonce.
        match apply_transaction(
            host,
            block_constants,
            precompiles,
            &transaction,
            block_in_progress.index,
            evm_account_storage,
            accounts_index,
        )? {
            Some((receipt_info, object_info)) => {
                block_in_progress.register_valid_transaction(
                    &transaction,
                    object_info,
                    receipt_info,
                    host,
                )?;
            }
            None => {
                block_in_progress.account_for_invalid_transaction();
            }
        };
    }
    Ok(ComputationResult::Finished)
}

pub fn produce<Host: Runtime>(
    host: &mut Host,
    queue: Queue,
) -> Result<(), anyhow::Error> {
    let (mut current_constants, mut current_block_number) =
        match storage::read_current_block(host) {
            Ok(block) => (block.constants(), block.number + 1),
            Err(_) => {
                let timestamp = current_timestamp(host);
                let timestamp = U256::from(timestamp.as_u64());
                (BlockConstants::first_block(timestamp), U256::zero())
            }
        };
    let mut evm_account_storage =
        init_account_storage().context("Failed to initialize EVM account storage")?;
    let mut accounts_index = init_account_index()?;
    let precompiles = precompiles::precompile_set::<Host>();
    let mut tick_counter = TickCounter::new(tick_model::top_level_overhead_ticks());

    for proposal in queue.proposals {
        let mut block_in_progress = bip_from_queue_element(
            proposal,
            current_block_number,
            &current_constants,
            tick_counter,
        );

        match compute(
            host,
            &mut block_in_progress,
            &current_constants,
            &precompiles,
            &mut evm_account_storage,
            &mut accounts_index,
        )? {
            ComputationResult::RebootNeeded => {
                log!(host, Info, "Ask for reboot");
                storage::store_block_in_progress(host, &block_in_progress)?;
                storage::add_reboot_flag(host)?;
                host.mark_for_reboot()?;
                // TODO: https://gitlab.com/tezos/tezos/-/issues/5873
                // store the queue
                return Ok(());
            }
            ComputationResult::Finished => {
                tick_counter = TickCounter::new(block_in_progress.estimated_ticks);
                let new_block = block_in_progress
                    .finalize_and_store(host)
                    .context("Failed to finalize the block in progress")?;
                current_block_number = new_block.number + 1;
                current_constants = new_block.constants();
                storage::delete_block_in_progress(host)?;
            }
        }
    }
    Ok(())
}

fn bip_from_queue_element(
    proposal: crate::blueprint::QueueElement,
    current_block_number: U256,
    constants: &BlockConstants,
    tick_counter: TickCounter,
) -> BlockInProgress {
    match proposal {
        crate::blueprint::QueueElement::Blueprint(proposal) => {
            // proposal is turn into a ring to allow poping from the front
            let ring = proposal.transactions.into();
            BlockInProgress::new_with_ticks(
                current_block_number,
                constants.gas_price,
                ring,
                tick_counter.c,
            )
        }
        crate::blueprint::QueueElement::BlockInProgress(mut bip) => {
            bip.estimated_ticks = tick_counter.c;
            bip
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::blueprint::{Blueprint, QueueElement};
    use crate::inbox::Transaction;
    use crate::inbox::TransactionContent;
    use crate::inbox::TransactionContent::Ethereum;
    use crate::indexable_storage::internal_for_tests::{get_value, length};
    use crate::storage::internal_for_tests::{
        read_transaction_receipt, read_transaction_receipt_status,
    };
    use crate::storage::{init_blocks_index, init_transaction_hashes_index};
    use crate::tick_model;
    use evm_execution::account_storage::{
        account_path, init_account_storage, EthereumAccountStorage,
    };
    use primitive_types::{H160, H256, U256};
    use std::collections::VecDeque;
    use std::ops::Rem;
    use std::str::FromStr;
    use tezos_ethereum::signatures::EthereumTransactionCommon;
    use tezos_ethereum::transaction::{
        TransactionHash, TransactionStatus, TRANSACTION_HASH_SIZE,
    };
    use tezos_smart_rollup_mock::MockHost;

    fn blueprint(transactions: Vec<Transaction>) -> QueueElement {
        QueueElement::Blueprint(Blueprint { transactions })
    }

    fn address_from_str(s: &str) -> Option<H160> {
        let data = &hex::decode(s).unwrap();
        Some(H160::from_slice(data))
    }
    fn string_to_h256_unsafe(s: &str) -> H256 {
        let mut v: [u8; 32] = [0; 32];
        hex::decode_to_slice(s, &mut v).expect("Could not parse to 256 hex value.");
        H256::from(v)
    }

    fn set_balance(
        host: &mut MockHost,
        evm_account_storage: &mut EthereumAccountStorage,
        address: &H160,
        balance: U256,
    ) {
        let mut account = evm_account_storage
            .get_or_create(host, &account_path(address).unwrap())
            .unwrap();
        let current_balance = account.balance(host).unwrap();
        if current_balance > balance {
            account
                .balance_remove(host, current_balance - balance)
                .unwrap();
        } else {
            account
                .balance_add(host, balance - current_balance)
                .unwrap();
        }
    }

    fn get_balance(
        host: &mut MockHost,
        evm_account_storage: &mut EthereumAccountStorage,
        address: &H160,
    ) -> U256 {
        let account = evm_account_storage
            .get_or_create(host, &account_path(address).unwrap())
            .unwrap();
        account.balance(host).unwrap()
    }

    fn dummy_eth_gen_transaction(
        nonce: U256,
        v: U256,
        r: H256,
        s: H256,
    ) -> EthereumTransactionCommon {
        let chain_id = U256::one();
        let gas_price = U256::from(40000000u64);
        let gas_limit = 21000u64;
        let to = address_from_str("423163e58aabec5daa3dd1130b759d24bef0f6ea");
        let value = U256::from(500000000u64);
        let data: Vec<u8> = vec![];
        EthereumTransactionCommon {
            chain_id,
            nonce,
            gas_price,
            gas_limit,
            to,
            value,
            data,
            v,
            r,
            s,
        }
    }

    fn dummy_eth_transaction_zero() -> EthereumTransactionCommon {
        // corresponding caller's address is 0xf95abdf6ede4c3703e0e9453771fbee8592d31e9
        // private key 0xe922354a3e5902b5ac474f3ff08a79cff43533826b8f451ae2190b65a9d26158
        let nonce = U256::zero();
        let v = U256::from(37);
        let r = string_to_h256_unsafe(
            "451d603fc1e73bb8c7afda6d4a0ce635657c812262f8d35aa0400504cec5af03",
        );
        let s = string_to_h256_unsafe(
            "562c20b430d8d137ef6ce0dc46a21f3ed4f810b7d27394af70684900be1a2e07",
        );
        dummy_eth_gen_transaction(nonce, v, r, s)
    }

    fn dummy_eth_transaction_one() -> EthereumTransactionCommon {
        // corresponding caller's address is 0xf95abdf6ede4c3703e0e9453771fbee8592d31e9
        // private key 0xe922354a3e5902b5ac474f3ff08a79cff43533826b8f451ae2190b65a9d26158
        let nonce = U256::one();
        let v = U256::from(37);
        let r = string_to_h256_unsafe(
            "624ebca1a42237859de4f0f90e4d6a6e8f73ed014656929abfe5664a039d1fc5",
        );
        let s = string_to_h256_unsafe(
            "4a08c518537102edd0c3c8c2125ef9ca45d32341a5b829a94b2f2f66e4f43eb0",
        );
        dummy_eth_gen_transaction(nonce, v, r, s)
    }

    fn dummy_eth_transaction_deploy_from_nonce_and_pk(
        nonce: u64,
        private_key: &str,
    ) -> EthereumTransactionCommon {
        let nonce = U256::from(nonce);
        let gas_price = U256::from(40000000000u64);
        let gas_limit = 42000u64;
        let value = U256::zero();
        // corresponding contract is kernel_benchmark/scripts/benchmarks/contracts/storage.sol
        let data: Vec<u8> = hex::decode("608060405234801561001057600080fd5b5061017f806100206000396000f3fe608060405234801561001057600080fd5b50600436106100415760003560e01c80634e70b1dc1461004657806360fe47b1146100645780636d4ce63c14610080575b600080fd5b61004e61009e565b60405161005b91906100d0565b60405180910390f35b61007e6004803603810190610079919061011c565b6100a4565b005b6100886100ae565b60405161009591906100d0565b60405180910390f35b60005481565b8060008190555050565b60008054905090565b6000819050919050565b6100ca816100b7565b82525050565b60006020820190506100e560008301846100c1565b92915050565b600080fd5b6100f9816100b7565b811461010457600080fd5b50565b600081359050610116816100f0565b92915050565b600060208284031215610132576101316100eb565b5b600061014084828501610107565b9150509291505056fea2646970667358221220ec57e49a647342208a1f5c9b1f2049bf1a27f02e19940819f38929bf67670a5964736f6c63430008120033").unwrap();

        let tx = EthereumTransactionCommon {
            chain_id: U256::one(),
            nonce,
            gas_price,
            gas_limit,
            to: None,
            value,
            data,
            v: U256::one(),
            r: H256::zero(),
            s: H256::zero(),
        };

        tx.sign_transaction(private_key.to_string()).unwrap()
    }

    fn dummy_eth_transaction_deploy() -> EthereumTransactionCommon {
        // corresponding caller's address is 0xaf1276cbb260bb13deddb4209ae99ae6e497f446
        dummy_eth_transaction_deploy_from_nonce_and_pk(
            0,
            "dcdff53b4f013dbcdc717f89fe3bf4d8b10512aae282b48e01d7530470382701",
        )
    }

    fn produce_block_with_several_valid_txs(
        host: &mut MockHost,
        evm_account_storage: &mut EthereumAccountStorage,
    ) {
        let tx_hash_0 = [0; TRANSACTION_HASH_SIZE];
        let tx_hash_1 = [1; TRANSACTION_HASH_SIZE];

        let transactions = vec![
            Transaction {
                tx_hash: tx_hash_0,
                content: Ethereum(dummy_eth_transaction_zero()),
            },
            Transaction {
                tx_hash: tx_hash_1,
                content: Ethereum(dummy_eth_transaction_one()),
            },
        ];

        let queue = Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        };

        let sender = H160::from_str("f95abdf6ede4c3703e0e9453771fbee8592d31e9").unwrap();
        set_balance(
            host,
            evm_account_storage,
            &sender,
            U256::from(10000000000000000000u64),
        );

        produce(host, queue).expect("The block production failed.")
    }

    fn assert_current_block_reading_validity(host: &mut MockHost) {
        match storage::read_current_block(host) {
            Ok(_) => (),
            Err(e) => {
                panic!("Block reading failed: {:?}\n", e)
            }
        }
    }

    #[test]
    // Test if the invalid transactions are producing receipts with invalid status
    fn test_invalid_transactions_receipt_status() {
        let mut host = MockHost::default();

        let tx_hash = [0; TRANSACTION_HASH_SIZE];

        let invalid_tx = Transaction {
            tx_hash,
            content: Ethereum(dummy_eth_transaction_zero()),
        };

        let transactions: Vec<Transaction> = vec![invalid_tx];
        let queue = Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        };

        produce(&mut host, queue).expect("The block production failed.");

        let status = read_transaction_receipt_status(&mut host, &tx_hash)
            .expect("Should have found receipt");
        assert_eq!(TransactionStatus::Failure, status);
    }

    #[test]
    // Test if a valid transaction is producing a receipt with a success status
    fn test_valid_transactions_receipt_status() {
        let mut host = MockHost::default();

        let tx_hash = [0; TRANSACTION_HASH_SIZE];

        let valid_tx = Transaction {
            tx_hash,
            content: Ethereum(dummy_eth_transaction_zero()),
        };

        let transactions: Vec<Transaction> = vec![valid_tx];
        let queue = Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        };

        let sender = H160::from_str("f95abdf6ede4c3703e0e9453771fbee8592d31e9").unwrap();
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            U256::from(5000000000000000u64),
        );

        produce(&mut host, queue).expect("The block production failed.");

        let status = read_transaction_receipt_status(&mut host, &tx_hash)
            .expect("Should have found receipt");
        assert_eq!(TransactionStatus::Success, status);
    }

    #[test]
    // Test if a valid transaction is producing a receipt with a contract address
    fn test_valid_transactions_receipt_contract_address() {
        let mut host = MockHost::default();

        let tx_hash = [0; TRANSACTION_HASH_SIZE];
        let tx = dummy_eth_transaction_deploy();
        assert_eq!(
            H160::from_str("af1276cbb260bb13deddb4209ae99ae6e497f446").unwrap(),
            tx.caller().unwrap()
        );
        let valid_tx = Transaction {
            tx_hash,
            content: Ethereum(dummy_eth_transaction_deploy()),
        };

        let transactions: Vec<Transaction> = vec![valid_tx];
        let queue = Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        };

        let sender = H160::from_str("af1276cbb260bb13deddb4209ae99ae6e497f446").unwrap();
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            U256::from(5000000000000000u64),
        );

        produce(&mut host, queue).expect("The block production failed.");

        let receipt = read_transaction_receipt(&mut host, &tx_hash)
            .expect("should have found receipt");
        assert_eq!(TransactionStatus::Success, receipt.status);
        assert_eq!(
            H160::from_str("af1276cbb260bb13deddb4209ae99ae6e497f446").unwrap(),
            receipt.from
        );
        assert_eq!(
            Some(H160::from_str("d9d427235f5746ffd1d5a0d850e77880a94b668f").unwrap()),
            receipt.contract_address
        );
    }

    #[test]
    // Test if several valid transactions can be performed
    fn test_several_valid_transactions() {
        let mut host = MockHost::default();
        let mut evm_account_storage = init_account_storage().unwrap();

        produce_block_with_several_valid_txs(&mut host, &mut evm_account_storage);

        let dest_address =
            H160::from_str("423163e58aabec5daa3dd1130b759d24bef0f6ea").unwrap();
        let dest_balance =
            get_balance(&mut host, &mut evm_account_storage, &dest_address);

        assert_eq!(dest_balance, U256::from(1000000000u64))
    }

    #[test]
    // Test if several valid proposals can produce valid blocks
    fn test_several_valid_proposals() {
        let mut host = MockHost::default();

        let tx_hash_0 = [0; TRANSACTION_HASH_SIZE];
        let tx_hash_1 = [1; TRANSACTION_HASH_SIZE];

        let transaction_0 = vec![Transaction {
            tx_hash: tx_hash_0,
            content: Ethereum(dummy_eth_transaction_zero()),
        }];

        let transaction_1 = vec![Transaction {
            tx_hash: tx_hash_1,
            content: Ethereum(dummy_eth_transaction_one()),
        }];

        let queue = Queue {
            proposals: vec![blueprint(transaction_0), blueprint(transaction_1)],
            kernel_upgrade: None,
        };

        let sender = H160::from_str("f95abdf6ede4c3703e0e9453771fbee8592d31e9").unwrap();
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            U256::from(10000000000000000000u64),
        );

        produce(&mut host, queue).expect("The block production failed.");

        let dest_address =
            H160::from_str("423163e58aabec5daa3dd1130b759d24bef0f6ea").unwrap();
        let dest_balance =
            get_balance(&mut host, &mut evm_account_storage, &dest_address);

        assert_eq!(dest_balance, U256::from(1000000000u64))
    }

    #[test]
    // Test transfers gas consumption consistency
    fn test_cumulative_transfers_gas_consumption() {
        let mut host = MockHost::default();
        let base_gas = U256::from(21000);

        let tx_hash_0 = [0; TRANSACTION_HASH_SIZE];
        let tx_hash_1 = [1; TRANSACTION_HASH_SIZE];

        let transactions = vec![
            Transaction {
                tx_hash: tx_hash_0,
                content: Ethereum(dummy_eth_transaction_zero()),
            },
            Transaction {
                tx_hash: tx_hash_1,
                content: Ethereum(dummy_eth_transaction_one()),
            },
        ];

        let queue = Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        };

        let sender = H160::from_str("f95abdf6ede4c3703e0e9453771fbee8592d31e9").unwrap();
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            U256::from(10000000000000000000u64),
        );

        produce(&mut host, queue).expect("The block production failed.");
        let receipt0 = read_transaction_receipt(&mut host, &tx_hash_0)
            .expect("should have found receipt");
        let receipt1 = read_transaction_receipt(&mut host, &tx_hash_1)
            .expect("should have found receipt");

        assert_eq!(receipt0.cumulative_gas_used, base_gas);
        assert_eq!(
            receipt1.cumulative_gas_used,
            receipt0.cumulative_gas_used + base_gas
        );
    }

    #[test]
    // Test if we're able to read current block (with a filled queue) after
    // a block production
    fn test_read_storage_current_block_after_block_production_with_filled_queue() {
        let mut host = MockHost::default();
        let mut evm_account_storage = init_account_storage().unwrap();

        produce_block_with_several_valid_txs(&mut host, &mut evm_account_storage);

        assert_current_block_reading_validity(&mut host);
    }

    #[test]
    // Test that the same transaction can not be replayed twice
    fn test_replay_attack() {
        let mut host = MockHost::default();

        let tx = Transaction {
            tx_hash: [0; TRANSACTION_HASH_SIZE],
            content: Ethereum(dummy_eth_transaction_zero()),
        };

        let transactions = vec![tx.clone(), tx];

        let queue = Queue {
            proposals: vec![blueprint(transactions.clone()), blueprint(transactions)],
            kernel_upgrade: None,
        };

        let sender = H160::from_str("f95abdf6ede4c3703e0e9453771fbee8592d31e9").unwrap();
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            U256::from(10000000000000000000u64),
        );

        produce(&mut host, queue).expect("The block production failed.");

        let dest_address =
            H160::from_str("423163e58aabec5daa3dd1130b759d24bef0f6ea").unwrap();
        let sender_balance = get_balance(&mut host, &mut evm_account_storage, &sender);
        let dest_balance =
            get_balance(&mut host, &mut evm_account_storage, &dest_address);

        assert_eq!(sender_balance, U256::from(9999999999500000000u64));
        assert_eq!(dest_balance, U256::from(500000000u64))
    }

    #[test]
    //Test accounts are indexed at the end of the block production
    fn test_accounts_are_indexed() {
        let mut host = MockHost::default();
        let accounts_index = init_account_index().unwrap();

        let tx = Transaction {
            tx_hash: [0; TRANSACTION_HASH_SIZE],
            content: Ethereum(dummy_eth_transaction_zero()),
        };

        let transactions = vec![tx];

        let queue = Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        };

        let indexed_accounts = length(&host, &accounts_index).unwrap();

        produce(&mut host, queue).expect("The block production failed.");

        let indexed_accounts_after_produce = length(&host, &accounts_index).unwrap();

        // The sender and receiver have never been indexed yet, and are indexed
        // whether the transaction succeeds or not.
        assert_eq!(
            indexed_accounts_after_produce,
            indexed_accounts + 2,
            "The new accounts haven't been indexed"
        )
    }

    #[test]
    //Test accounts are indexed at the end of the block production
    fn test_accounts_are_indexed_once() {
        let mut host = MockHost::default();
        let accounts_index = init_account_index().unwrap();

        let tx = Transaction {
            tx_hash: [0; TRANSACTION_HASH_SIZE],
            content: Ethereum(dummy_eth_transaction_zero()),
        };

        let transactions = vec![tx];

        let queue = Queue {
            proposals: vec![blueprint(transactions.clone())],
            kernel_upgrade: None,
        };

        produce(&mut host, queue).expect("The block production failed.");

        let indexed_accounts = length(&host, &accounts_index).unwrap();

        let next_queue = Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        };

        produce(&mut host, next_queue).expect("The block production failed.");

        let indexed_accounts_after_second_produce =
            length(&host, &accounts_index).unwrap();

        // The sender and receiver have never been indexed yet
        assert_eq!(
            indexed_accounts, indexed_accounts_after_second_produce,
            "Accounts have been indexed twice"
        )
    }

    #[test]
    fn test_blocks_and_transactions_are_indexed() {
        let mut host = MockHost::default();
        let blocks_index = init_blocks_index().unwrap();
        let transaction_hashes_index = init_transaction_hashes_index().unwrap();

        let tx_hash = [0; TRANSACTION_HASH_SIZE];

        let tx = Transaction {
            tx_hash,
            content: Ethereum(dummy_eth_transaction_zero()),
        };

        let transactions = vec![tx];

        let queue = Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        };

        let number_of_blocks_indexed = length(&host, &blocks_index).unwrap();
        let number_of_transactions_indexed =
            length(&host, &transaction_hashes_index).unwrap();

        let sender = H160::from_str("f95abdf6ede4c3703e0e9453771fbee8592d31e9").unwrap();
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            U256::from(10000000000000000000u64),
        );
        produce(&mut host, queue).expect("The block production failed.");

        let new_number_of_blocks_indexed = length(&host, &blocks_index).unwrap();
        let new_number_of_transactions_indexed =
            length(&host, &transaction_hashes_index).unwrap();

        let current_block_hash = storage::read_current_block(&mut host)
            .unwrap()
            .hash
            .as_bytes()
            .to_vec();

        assert_eq!(number_of_blocks_indexed + 1, new_number_of_blocks_indexed);
        assert_eq!(
            number_of_transactions_indexed + 1,
            new_number_of_transactions_indexed
        );

        assert_eq!(
            Ok(current_block_hash),
            get_value(&host, &blocks_index, new_number_of_blocks_indexed - 1)
        );

        let last_indexed_transaction =
            length(&host, &transaction_hashes_index).unwrap() - 1;

        assert_eq!(
            Ok(tx_hash.to_vec()),
            get_value(&host, &transaction_hashes_index, last_indexed_transaction)
        );
    }

    fn first_block<MockHost: Runtime>(host: &mut MockHost) -> BlockConstants {
        let timestamp = current_timestamp(host);
        let timestamp = U256::from(timestamp.as_u64());
        BlockConstants::first_block(timestamp)
    }

    fn compute_block<MockHost: Runtime>(
        transactions: VecDeque<Transaction>,
        host: &mut MockHost,
        mut evm_account_storage: EthereumAccountStorage,
    ) -> BlockInProgress {
        let block_constants = first_block(host);
        let precompiles = precompiles::precompile_set::<MockHost>();
        let mut accounts_index = init_account_index().unwrap();

        // init block in progress
        let mut block_in_progress =
            BlockInProgress::new(U256::from(1), U256::from(1), transactions);

        compute::<MockHost>(
            host,
            &mut block_in_progress,
            &block_constants,
            &precompiles,
            &mut evm_account_storage,
            &mut accounts_index,
        )
        .expect("Should have computed block");
        block_in_progress
    }

    #[test]
    fn test_ticks_valid_transaction() {
        // init host
        let mut host = MockHost::default();

        //provision sender account
        let sender = H160::from_str("af1276cbb260bb13deddb4209ae99ae6e497f446").unwrap();
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            U256::from(5000000000000000u64),
        );

        // tx is valid because correct nonce and account provisionned
        let valid_tx = Transaction {
            tx_hash: [0; TRANSACTION_HASH_SIZE],
            content: TransactionContent::Ethereum(dummy_eth_transaction_deploy()),
        };

        let transactions = vec![valid_tx].into();

        // act
        let block_in_progress =
            compute_block(transactions, &mut host, evm_account_storage);

        // assert
        let ticks = block_in_progress.estimated_ticks;
        let block = block_in_progress
            .finalize_and_store(&mut host)
            .expect("should have succeeded in processing block");

        assert_eq!(
            block.gas_used,
            U256::from(21123),
            "Gas used for contract creation"
        );

        assert_eq!(
            ticks,
            tick_model::ticks_of_gas(21123) + tick_model::top_level_overhead_ticks()
        );
    }

    #[test]
    fn test_ticks_invalid() {
        // init host
        let mut host = MockHost::default();
        let evm_account_storage = init_account_storage().unwrap();

        // tx is invalid because wrong nonce
        let valid_tx = Transaction {
            tx_hash: [0; TRANSACTION_HASH_SIZE],
            content: TransactionContent::Ethereum(
                dummy_eth_transaction_deploy_from_nonce_and_pk(
                    42,
                    "e922354a3e5902b5ac474f3ff08a79cff43533826b8f451ae2190b65a9d26158",
                ),
            ),
        };

        let transactions = vec![valid_tx].into();

        // act
        let block_in_progress =
            compute_block(transactions, &mut host, evm_account_storage);

        // assert
        let ticks = block_in_progress.estimated_ticks;
        let block = block_in_progress
            .finalize_and_store(&mut host)
            .expect("should be able to finalize block");

        assert_eq!(block.gas_used, U256::zero(), "no gas used");
        // crypto + tx overhead + init overhead
        assert_eq!(
            ticks,
            tick_model::ticks_of_invalid_transaction()
                + tick_model::top_level_overhead_ticks()
        );
    }

    #[test]
    fn test_stop_computation() {
        // init host
        let mut host = MockHost::default();
        let block_constants = first_block(&mut host);
        let precompiles = precompiles::precompile_set::<MockHost>();
        let mut accounts_index = init_account_index().unwrap();

        //provision sender account
        let sender = H160::from_str("af1276cbb260bb13deddb4209ae99ae6e497f446").unwrap();
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            U256::from(10000000000000000000u64),
        );

        // tx is valid because correct nonce and account provisionned
        let valid_tx = Transaction {
            tx_hash: [0; TRANSACTION_HASH_SIZE],
            content: TransactionContent::Ethereum(dummy_eth_transaction_zero()),
        };
        let transactions = vec![valid_tx].into();

        // init block in progress
        let mut block_in_progress =
            BlockInProgress::new(U256::from(1), U256::from(1), transactions);
        // block is almost full wrt ticks
        block_in_progress.estimated_ticks = tick_model::MAX_TICKS - 1000;

        // act
        compute::<MockHost>(
            &mut host,
            &mut block_in_progress,
            &block_constants,
            &precompiles,
            &mut evm_account_storage,
            &mut accounts_index,
        )
        .expect("Should have computed block");

        // assert

        // block in progress should not have registered any gas or ticks
        assert_eq!(
            block_in_progress.cumulative_gas,
            U256::from(0),
            "should not have consumed any gas"
        );
        assert_eq!(
            block_in_progress.estimated_ticks,
            tick_model::MAX_TICKS - 1000,
            "should not have consumed any tick"
        );

        // the transaction should not have been processed
        let dest_address =
            H160::from_str("423163e58aabec5daa3dd1130b759d24bef0f6ea").unwrap();
        let sender_balance = get_balance(&mut host, &mut evm_account_storage, &sender);
        let dest_balance =
            get_balance(&mut host, &mut evm_account_storage, &dest_address);
        assert_eq!(sender_balance, U256::from(10000000000000000000u64));
        assert_eq!(dest_balance, U256::from(0u64))
    }

    #[test]
    fn invalid_transaction_should_bump_nonce() {
        let mut host = MockHost::default();
        let evm_account_storage = init_account_storage().unwrap();

        let caller =
            address_from_str("f95abdf6ede4c3703e0e9453771fbee8592d31e9").unwrap();

        // Get the balance before the transaction, i.e. 0.
        let caller_account = evm_account_storage
            .get_or_create(&host, &account_path(&caller).unwrap())
            .unwrap();
        let default_nonce = caller_account.nonce(&host).unwrap();
        assert_eq!(default_nonce, U256::zero(), "default nonce should be 0");

        // Prepare a invalid transaction, i.e. with not enough funds.
        let tx_hash = [0; TRANSACTION_HASH_SIZE];
        let transaction = Transaction {
            tx_hash,
            content: Ethereum(dummy_eth_transaction_zero()),
        };
        let queue = Queue {
            proposals: vec![blueprint(vec![transaction])],
            kernel_upgrade: None,
        };

        // Apply the transaction
        produce(&mut host, queue).expect("The block production failed.");
        let receipt = read_transaction_receipt(&mut host, &tx_hash)
            .expect("should have found receipt");
        assert_eq!(
            receipt.status,
            TransactionStatus::Failure,
            "transaction should have failed"
        );

        // Nonce should have been bumped
        let nonce = caller_account.nonce(&host).unwrap();
        assert_eq!(nonce, default_nonce + 1, "nonce should have been bumped");
    }

    /// A queue that should produce 1 block with an invalid transaction
    fn almost_empty_queue() -> Queue {
        let tx_hash = [0; TRANSACTION_HASH_SIZE];

        // transaction should be invalid
        let tx = Transaction {
            tx_hash,
            content: Ethereum(dummy_eth_transaction_one()),
        };

        let transactions = vec![tx];

        Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        }
    }

    fn check_current_block_number<Host: Runtime>(host: &mut Host, nb: usize) {
        let current_nb = storage::read_current_block_number(host)
            .expect("Should have manage to check block number");
        assert_eq!(current_nb, U256::from(nb), "Incorrect block number");
    }

    #[test]
    fn test_first_blocks() {
        let mut host = MockHost::default();

        // first block should be 0
        produce(&mut host, almost_empty_queue())
            .expect("Empty block should have been produced");
        check_current_block_number(&mut host, 0);

        // second block
        produce(&mut host, almost_empty_queue())
            .expect("Empty block should have been produced");
        check_current_block_number(&mut host, 1);

        // third block
        produce(&mut host, almost_empty_queue())
            .expect("Empty block should have been produced");
        check_current_block_number(&mut host, 2);
    }

    fn dummy_eth(nonce: u64) -> EthereumTransactionCommon {
        let nonce = U256::from(nonce);
        let gas_price = U256::from(40000000000u64);
        let gas_limit = 21000;
        let value = U256::from(1);
        let to = address_from_str("423163e58aabec5daa3dd1130b759d24bef0f6ea");
        let tx = EthereumTransactionCommon {
            chain_id: U256::one(),
            nonce,
            gas_price,
            gas_limit,
            to,
            value,
            data: vec![],
            v: U256::one(),
            r: H256::zero(),
            s: H256::zero(),
        };

        // corresponding caller's address is 0xaf1276cbb260bb13deddb4209ae99ae6e497f446
        tx.sign_transaction(
            "dcdff53b4f013dbcdc717f89fe3bf4d8b10512aae282b48e01d7530470382701"
                .to_string(),
        )
        .unwrap()
    }

    fn hash_from_nonce(nonce: u64) -> TransactionHash {
        let nonce = u64::to_le_bytes(nonce);
        let mut hash = [0; 32];
        hash[..8].copy_from_slice(&nonce);
        hash
    }

    fn dummy_transaction(nonce: u64) -> Transaction {
        Transaction {
            tx_hash: hash_from_nonce(nonce),
            content: TransactionContent::Ethereum(dummy_eth(nonce)),
        }
    }

    const TOO_MANY_TRANSACTIONS: u64 = 500;

    #[test]
    fn test_reboot_many_tx_one_proposal() {
        // init host
        let mut host = MockHost::default();

        // sanity check: no current block
        assert!(
            storage::read_current_block_number(&mut host).is_err(),
            "Should not have found current block number"
        );

        //provision sender account
        let sender = H160::from_str("af1276cbb260bb13deddb4209ae99ae6e497f446").unwrap();
        let sender_initial_balance = U256::from(10000000000000000000u64);
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            sender_initial_balance,
        );

        let mut transactions = vec![];
        for n in 0..TOO_MANY_TRANSACTIONS {
            transactions.push(dummy_transaction(n));
        }
        let queue = Queue {
            proposals: vec![blueprint(transactions)],
            kernel_upgrade: None,
        };

        produce(&mut host, queue).expect("Should have produced");

        // test no new block
        assert!(
            storage::read_current_block_number(&mut host).is_err(),
            "Should not have found current block number"
        );

        // test reboot is set
        assert!(
            storage::was_rebooted(&mut host).expect("Should have found flag"),
            "Flag should be set"
        );
    }

    #[test]
    fn test_reboot_many_tx_many_proposal() {
        // init host
        let mut host = MockHost::default();

        // sanity check: no current block
        assert!(
            storage::read_current_block_number(&mut host).is_err(),
            "Should not have found current block number"
        );

        //provision sender account
        let sender = H160::from_str("af1276cbb260bb13deddb4209ae99ae6e497f446").unwrap();
        let sender_initial_balance = U256::from(10000000000000000000u64);
        let mut evm_account_storage = init_account_storage().unwrap();
        set_balance(
            &mut host,
            &mut evm_account_storage,
            &sender,
            sender_initial_balance,
        );

        let mut transactions = vec![];
        let mut proposals = vec![];
        for n in 1..TOO_MANY_TRANSACTIONS {
            transactions.push(dummy_transaction(n));
            if n.rem(100) == 0 {
                proposals.push(blueprint(transactions));
                transactions = vec![];
            }
        }
        let queue = Queue {
            proposals,
            kernel_upgrade: None,
        };

        produce(&mut host, queue).expect("Should have produced");

        // test no new block
        assert!(
            storage::read_current_block_number(&mut host)
                .expect("should have found a block number")
                > U256::zero(),
            "There should have been multiple blocks registered"
        );

        // test reboot is set
        assert!(
            storage::was_rebooted(&mut host).expect("Should have found flag"),
            "Flag should be set"
        );
    }
}
