KERNELS = evm_kernel.wasm sequenced_kernel.wasm tx_kernel.wasm
SDK_DIR=src/kernel_sdk
EVM_DIR=src/kernel_evm
DEMO_DIR=src/kernel_tx_demo
SEQUENCER_DIR=src/kernel_sequencer
EVM_KERNEL_PREIMAGES = _evm_installer_preimages

.PHONY: all
all: build-dev-deps check test build


.PHONY: kernel_sdk
kernel_sdk:
	@make -C src/kernel_sdk build
	@cp src/kernel_sdk/target/$(NATIVE_TARGET)/release/smart-rollup-installer .

evm_kernel.wasm::
	@make -C src/kernel_evm build
	@cp src/kernel_evm/target/wasm32-unknown-unknown/release/evm_kernel.wasm $@
	@wasm-strip $@

evm_installer.wasm:: kernel_sdk evm_kernel.wasm
ifdef EVM_CONFIG
	$(eval CONFIG := --setup-file ${EVM_CONFIG})
endif
	@./smart-rollup-installer get-reveal-installer \
	--upgrade-to evm_kernel.wasm \
	--preimages-dir ${EVM_KERNEL_PREIMAGES} \
	--output $@ \
	${CONFIG}

evm_installer_dev.wasm::
	@${MAKE} -f kernels.mk EVM_CONFIG=src/kernel_evm/config/dev.yaml evm_installer.wasm

sequenced_kernel.wasm:
	@make -C src/kernel_sequencer build
	@cp src/kernel_sequencer/target/wasm32-unknown-unknown/release/examples/sequenced_kernel.wasm $@
	@wasm-strip $@

.PHONY: tx_demo_collector
tx_demo_collector:
	@make -C src/kernel_tx_demo build
	@cp src/kernel_tx_demo/target/$(NATIVE_TARGET)/release/tx-demo-collector .

tx_kernel.wasm: tx_demo_collector
	@cp src/kernel_tx_demo/target/wasm32-unknown-unknown/release/tx_kernel.wasm $@

.PHONY: build
build: ${KERNELS} kernel_sdk

.PHONY: build-dev-deps
build-dev-deps: build-deps
	@make -C ${SDK_DIR} build-dev-deps
	@make -C ${EVM_DIR} build-dev-deps
	@make -C ${SEQUENCER_DIR} build-dev-deps
	@make -C ${DEMO_DIR} build-dev-deps

.PHONY: build-deps
build-deps:
	@make -C ${SDK_DIR} build-deps
	@make -C ${EVM_DIR} build-deps
	@make -C ${SEQUENCER_DIR} build-deps
	@make -C ${DEMO_DIR} build-deps

.PHONY: test
test:
	@make -C ${SDK_DIR} test
	@make -C ${EVM_DIR} test
	@make -C ${SEQUENCER_DIR} test
	@make -C ${DEMO_DIR} test

.PHONY: check
check:
	@make -C ${SDK_DIR} check
	@make -C ${EVM_DIR} check
	@make -C ${SEQUENCER_DIR} check
	@make -C ${DEMO_DIR} check

.PHONY: publish-sdk-deps
publish-sdk-deps: build-deps
	@make -C ${SDK_DIR} publish-deps

.PHONY: publish-sdk
publish-sdk:
	@make -C ${SDK_DIR} publish

.PHONY: clean
clean:
	@rm -f ${KERNELS}
	@make -C ${SDK_DIR} clean
	@make -C ${EVM_DIR} clean
	@make -C ${SEQUENCER_DIR} clean
	@make -C ${DEMO_DIR} clean
	@rm -rf ${EVM_KERNEL_PREIMAGES}
