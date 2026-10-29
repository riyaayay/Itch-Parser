# =============================================================================
# File        : model/test_model.py
# Spec Section: 12.2 (MDL-1, MDL-2, BK-W)
# Description : Verification suite for the Python Golden Reference Model.
# Copyright (c) 2026 Riya Rathod. Licensed under the MIT License.
# =============================================================================

import unittest
from model.itch import test_mdl1, encode_itch_message, parse_itch_block, HANDLED_TYPES
from model.framer import AxisFramerModel
from model.table import OrderTableModel, BookOp, OP_ADD, OP_REDUCE, OP_CORRUPT, SIDE_BID, SIDE_ASK
from model.book import OrderBookModel, test_bkw
from model.trigger import TriggerModel, TriggerConfig, RULE_CROSS_BUY
from model.risk import RiskEngineModel, RiskSymbolConfig, RSN_PASS, RSN_COLLAR
from model.encoder import EncoderModel


class TestGoldenReferenceModel(unittest.TestCase):
    def test_mdl1_gate(self):
        """MDL-1: ITCH 5.0 wire formats and length tables."""
        self.assertTrue(test_mdl1())

    def test_mdl2_bkw_gate(self):
        """MDL-2: Book invariants and BK-W 10-step reference scenario."""
        self.assertTrue(test_bkw())

    def test_end_to_end_pipeline(self):
        """Verify full path from AXI-Stream beat to 48-byte OUCH order."""
        symbols = [b"AAPL    ", b"SPY     ", b"MSFT    "]
        framer = AxisFramerModel()
        table = OrderTableModel(symbols=symbols)
        book = OrderBookModel(num_symbols=len(symbols), book_n=8)
        trigger = TriggerModel(num_symbols=len(symbols))
        risk = RiskEngineModel(num_symbols=len(symbols))
        encoder = EncoderModel(symbols=symbols)

        # Configure symbol 0 (AAPL)
        trigger.configs[0] = TriggerConfig(
            en=True,
            rule_mask=0x0F,
            imb_shift=0,
            buy_limit=1600000,
            sell_limit=1400000,
            max_spread=50000,
            qty=100
        )
        risk.sym_configs[0] = RiskSymbolConfig(
            cfg_valid=True,
            max_qty=500,
            max_notional=200_000_000,
            collar_abs=100000,
            ref_px=1500000,
            max_pos=1000
        )

        # Generate two orders: Bid at 1490000 (100 sh), Ask at 1510000 (100 sh)
        raw_msg1 = encode_itch_message(
            msg_type=0x41, locate=1, ref=1001, side=ord('B'), shares=100, stock=b"AAPL    ", price=1490000
        )
        raw_msg2 = encode_itch_message(
            msg_type=0x41, locate=1, ref=1002, side=ord('S'), shares=100, stock=b"AAPL    ", price=1510000
        )

        stream = raw_msg1 + raw_msg2
        beats = AxisFramerModel.pack_stream_into_beats(stream)

        blocks = list(framer.process_frame_beats(beats))
        self.assertEqual(len(blocks), 2)

        outbound_frames = []
        for blk in blocks:
            msg = parse_itch_block(blk.idx, blk.stored_len, blk.payload[:blk.stored_len])
            ops = table.process_message(msg)
            for op in ops:
                upd = book.apply_op(op)
                cand = trigger.evaluate(upd)
                if cand:
                    dec = risk.evaluate(cand)
                    frame = encoder.encode(dec, cand.rule)
                    if frame:
                        outbound_frames.append(frame)

        # Spread was 1510000 - 1490000 = 20000 <= max_spread (50000)
        # Ask was 1510000 <= buy_limit (1600000) -> CROSS_BUY should fire!
        self.assertEqual(len(outbound_frames), 1)
        frame = outbound_frames[0]
        self.assertEqual(frame.user_ref, 1)
        self.assertEqual(frame.rule_id, RULE_CROSS_BUY)
        self.assertEqual(frame.qty, 100)
        self.assertEqual(frame.price, 1510000)
        self.assertEqual(frame.stock, b"AAPL    ")
        self.assertEqual(len(frame.frame_bytes), 48)


if __name__ == "__main__":
    unittest.main()
