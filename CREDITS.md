# Credits & License Attribution

## Upstream Repository Attribution
- **Upstream Repository:** `tmlee06/Itch-Parser` (`https://github.com/tmlee06/Itch-Parser`)
- **Upstream Author:** tmlee06
- **License Status (Decision D2 / Section 3.3):** Upstream `README.md` states `MIT`, but no `LICENSE` file is present in the upstream repository listing (`F1`). Until written confirmation from the upstream author is recorded below, upstream files are treated as all-rights-reserved, and this repository remains private.

### Upstream Author Permission Record
- **Status:** Pending written confirmation (`derived-pending-permission`).
- **Correspondence Log:** *[Paste link to GitHub Issue or email reply from tmlee06 here once received]*

## File Classification Inventory (Section 3.3 Rule 5)

### 1. Unmodified Upstream Files (Copyright `tmlee06`, All Rights Reserved Pending Confirmation)
Copied byte-for-byte into `upstream/` with SHA-256 digests logged in `upstream/UPSTREAM.md`:
- `upstream/itch_decoder.v`
- `upstream/order_book.v`
- `upstream/axis_512_to_8_adapter.v`
- `upstream/top_parser_to_lab.v`
- `upstream/hft_trading_kernel.v`
- `upstream/tb_axis_adapter.v`
- `upstream/tb_itch_decoder_real_data.v`
- `upstream/sim_data.hex` (also archived at `vectors/legacy/sim_data_raw.hex`)

### 2. Files Derived from Upstream (`derived-pending-permission`)
- `rtl/ref/itch_decoder_ref.v`: Derived from `upstream/itch_decoder.v` for reference-mode verification (`EX-10`) only.
  - **Exact edits made:** Fixed Findings `F2` and `F3` where `next_state` transitioned to `IDLE` on the final payload byte (`byte_count == msg_length - 1`), preventing `order_price[7:0]` capture and preventing `order_valid` from pulsing.

### 3. Original Files (Copyright (c) 2026 riyaayay, MIT License)
All files under `rtl/` (excluding `rtl/ref/itch_decoder_ref.v`), `model/`, `tools/`, `tb/`, `formal/`, `vivado/`, `scripts/`, and `docs/`.
