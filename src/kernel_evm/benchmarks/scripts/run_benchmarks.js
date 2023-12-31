// SPDX-FileCopyrightText: 2023 TriliTech <contact@trili.tech>
//
// SPDX-License-Identifier: MIT

// This script runs the benchmarks for the EVM kernel and writes the result to benchmark_result.csv

// Before running this script, run the following commands to build the debugger and the benchmark kernel
// $ make 
// $ make -C src/kernel_evm/

// Then run this script using the following command
// $ node src/kernel_evm/kernel_benchmark/scripts/run_benchmarks.js

// Each row of the output file represents the processing of one message in the kernel
// Each value represents a cost. "gas_cost" is the cost in gas in the EVM, and the other values are costs in ticks in the PVM

var fs = require('fs');
var readline = require('readline');
const { spawn } = require('child_process');
const { execSync } = require('child_process');

// TODO: Remove Hardcoded Paths
// issue: https://gitlab.com/tezos/tezos/-/issues/6175
const RUN_DEBUGGER_COMMAND = './octez-smart-rollup-wasm-debugger';
const RUN_INSTALLER_COMMAND = 'src/kernel_sdk/target/release/smart-rollup-installer'
const EVM_INSTALLER_KERNEL_PATH = 'evm_installer.wasm';
const PREIMAGE_DIR = 'preimages';
const SETUP_FILE_PATH = 'src/kernel_evm/config/benchmarking.yaml';
const EVM_KERNEL_PATH = 'src/kernel_evm/target/wasm32-unknown-unknown/release/evm_kernel.wasm';

function sumArray(arr) {
    return arr.reduce((acc, curr) => acc + curr, 0);
}
  
function run_profiler(path) {

    profiler_result = new Promise ((resolve, _) => {

        var gas_used = [];

        var profiler_output_path = "";

        const args = ["--kernel", EVM_INSTALLER_KERNEL_PATH, "--inputs", path, "--preimage-dir", PREIMAGE_DIR];

        const childProcess = spawn(RUN_DEBUGGER_COMMAND, args, {});

        childProcess.stdin.write("load inputs\n");

        childProcess.stdin.write("step kernel_run\n");

        childProcess.stdin.write("profile\n");

        childProcess.stdin.end();

        childProcess.stdout.on('data', (data) => {
            const output = data.toString();
                const profiler_output_path_regex = /Profiling result can be found in (.+)/;
                const profiler_output_path_match = output.match(profiler_output_path_regex);
                const profiler_output_path_result = profiler_output_path_match 
                    ? profiler_output_path_match[1] 
                    : null;
                if (profiler_output_path_result !== null) {
                    profiler_output_path = profiler_output_path_result;
                }
                const gas_used_regex = /\bgas_used:\s*(\d+)/g;
                var match;
                while ((match = gas_used_regex.exec(output))) {
                    gas_used.push(match[1]);
                }
        });
        childProcess.on('close', _ => {
            if (profiler_output_path == "") {
                console.log(new Error("Profiler output path not found"));
            }
            if (gas_used == []) {
                console.log(new Error("Gas usage data not found"));
            }
            resolve([profiler_output_path, gas_used]);
        });
    })
    return profiler_result;
}

// Helper function to count the number of ticks of given function call
async function get_ticks(path, function_call_keyword) {
    const fileStream = fs.createReadStream(path);
    var ticks_count_for_transactions = [];
    var previous_row_is_given_function_call = false;

    const rl = readline.createInterface({
        input: fileStream,
        crlfDelay: Infinity
      });

      for await (const l of rl) {
        if (l !== "") {
            tokens = l.split(" ");
            calls = tokens[0];
            ticks = tokens[1];
            if (calls.includes(function_call_keyword)) {
                if (previous_row_is_given_function_call) {
                    ticks_count_for_transactions[ticks_count_for_transactions.length - 1] += parseInt(ticks);
                } else {
                    ticks_count_for_transactions.push(parseInt(ticks));
                    previous_row_is_given_function_call = true
                }
            } else {
                previous_row_is_given_function_call = false;
            }
        }
      }

    return ticks_count_for_transactions;
}

// Parse the profiler output file and get the tick counts of the differerent function calls
async function analyze_profiler_output(path) {

    kernel_run_ticks = await get_ticks(path, "kernel_run");
    run_transaction_ticks = await get_ticks(path, "run_transaction");
    signature_verification_ticks = await get_ticks(path, "tezos_ethereum10signatures");
    store_transaction_object_ticks = await get_ticks(path, "storage24store_transaction_object");
    interpreter_init_ticks = await get_ticks(path, "interpreter(init)");
    interpreter_decode_ticks = await get_ticks(path, "interpreter(decode)");
    fetch_blueprint_ticks = await get_ticks(path, "blueprint5fetch");
    return {
        kernel_run_ticks: kernel_run_ticks,
        run_transaction_ticks: run_transaction_ticks,
        signature_verification_ticks: signature_verification_ticks,
        store_transaction_object_ticks: store_transaction_object_ticks,
        interpreter_init_ticks: interpreter_init_ticks,
        interpreter_decode_ticks: interpreter_decode_ticks,
        fetch_blueprint_ticks: fetch_blueprint_ticks,
    };
}

// Run given benchmark 
async function run_benchmark(path) {
    run_profiler_result = await run_profiler(path);
    profiler_output_path = run_profiler_result[0];
    gas_costs = run_profiler_result[1];
    profiler_output_analysis_result = await analyze_profiler_output(profiler_output_path);
    profiler_output_analysis_result.gas_costs = gas_costs;
    return profiler_output_analysis_result;
}

function build_evm_installer_kernel_for_benchmark() {
    try {
        execSync(`${RUN_INSTALLER_COMMAND} get-reveal-installer --upgrade-to ${EVM_KERNEL_PATH} --output ${EVM_INSTALLER_KERNEL_PATH} --preimages-dir ${PREIMAGE_DIR} --setup-file ${SETUP_FILE_PATH}`);
    } catch (error) {
        console.log("Error building evm kernel installer");
        console.error(error);
    }
}

function build_benchmark_scenario(benchmark_script) {
    try {
        execSync(`node ${benchmark_script} > transactions.json`);
    } catch (error) {
        console.log(`Error running script ${benchmark_script}. Please fixed the error in the script before running this benchmark script`)
        console.error(error);
    }
}

function log_benchmark_result(benchmark_name, run_benchmark_result) {
    rows = [];
    gas_costs = run_benchmark_result.gas_costs;
    kernel_run_ticks = run_benchmark_result.kernel_run_ticks;
    run_transaction_ticks=run_benchmark_result.run_transaction_ticks;
    signature_verification_ticks = run_benchmark_result.signature_verification_ticks;
    store_transaction_object_ticks = run_benchmark_result.store_transaction_object_ticks;
    interpreter_init_ticks = run_benchmark_result.interpreter_init_ticks;
    interpreter_decode_ticks = run_benchmark_result.interpreter_decode_ticks;
    fetch_blueprint_ticks = run_benchmark_result.fetch_blueprint_ticks;

    unaccounted_ticks = sumArray(kernel_run_ticks) - sumArray(run_transaction_ticks) - sumArray(signature_verification_ticks) - sumArray(store_transaction_object_ticks) - sumArray(fetch_blueprint_ticks)

    for (var j = 0; j < gas_costs.length; j++) {
        rows.push([benchmark_name, gas_costs[j], run_transaction_ticks[j], signature_verification_ticks[j], store_transaction_object_ticks[j], "", "", "", "", ""]);
    }

    for (var j = 0; j < kernel_run_ticks.length; j++) {
        rows.push([benchmark_name + "(all)", "", "", "", "", interpreter_init_ticks[j], interpreter_decode_ticks[j], fetch_blueprint_ticks[j], kernel_run_ticks[j], ""]);
    }
    rows.push([benchmark_name + "(all)", "", "", "", "", "", "", "", "", unaccounted_ticks]);
    return rows;
}

// Run the benchmark suite and write the result to benchmark_result.csv
async function run_all_benchmarks(benchmark_scripts) {
    console.log(`Running benchmarks on: [${benchmark_scripts.join('\n  ')}]`);
    var fields = ["benchmark_name", "gas_cost", "run_transaction_ticks", "signature_verification_ticks", "store_transaction_object_ticks" ,"interpreter_init_ticks", "interpreter_decode_ticks", "fetch_blueprint_ticks", "kernel_run_ticks", "unaccounted_ticks"];
    fs.writeFileSync('benchmark_result.csv', fields.join(",") + "\n");
    for (var i = 0; i < benchmark_scripts.length; i++) {
        var benchmark_script = benchmark_scripts[i];
        var parts = benchmark_script.split("/");
        var benchmark_name = parts[parts.length - 1].split(".")[0];
        console.log(`Benchmarking ${benchmark_script}`);
        build_benchmark_scenario(benchmark_script);
        run_benchmark_result = await run_benchmark("transactions.json");
        benchmark_log  = log_benchmark_result(benchmark_name, run_benchmark_result);
        fs.appendFileSync('benchmark_result.csv', benchmark_log.map(row => row.join(",")).join("\n") + "\n");
    }
    console.log("Benchmarking complete");
    execSync("rm transactions.json");
}

benchmark_scripts = [
    // TODO: Remove Hardcoded Paths
    // issue: https://gitlab.com/tezos/tezos/-/issues/6175
    "src/kernel_evm/benchmarks/scripts/benchmarks/bench_storage_1.js",
    "src/kernel_evm/benchmarks/scripts/benchmarks/bench_storage_2.js",
    "src/kernel_evm/benchmarks/scripts/benchmarks/bench_transfers_1.js",
    "src/kernel_evm/benchmarks/scripts/benchmarks/bench_transfers_2.js",
    "src/kernel_evm/benchmarks/scripts/benchmarks/bench_transfers_3.js",
    "src/kernel_evm/benchmarks/scripts/benchmarks/bench_keccak.js",
    "src/kernel_evm/benchmarks/scripts/benchmarks/bench_verifySignature.js",
    "src/kernel_evm/benchmarks/scripts/benchmarks/bench_erc20tok.js",
    "src/kernel_evm/benchmarks/scripts/benchmarks/bench_loop.js",
]
build_evm_installer_kernel_for_benchmark();
run_all_benchmarks(benchmark_scripts);
