meta:
  id: id_008__ptedo2zk__block_header__unsigned
  endian: be
  imports:
  - block_header__shell
doc: ! 'Encoding id: 008-PtEdo2Zk.block_header.unsigned'
types:
  id_008__ptedo2zk__block_header__alpha__unsigned_contents:
    seq:
    - id: priority
      type: u2be
    - id: proof_of_work_nonce
      size: 8
    - id: seed_nonce_hash_tag
      type: u1
      enum: bool
    - id: seed_nonce_hash
      size: 32
      if: (seed_nonce_hash_tag == bool::true)
enums:
  bool:
    0: false
    255: true
seq:
- id: id_008__ptedo2zk__block_header__unsigned
  type: block_header__shell
- id: id_008__ptedo2zk__block_header__alpha__unsigned_contents
  type: id_008__ptedo2zk__block_header__alpha__unsigned_contents
