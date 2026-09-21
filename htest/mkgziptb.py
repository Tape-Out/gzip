"""gzip 的行为测试台：Python 的 zlib 当参照实现生成向量，被测件解出的每个字节都要对上。

有效的流都用与这一点同样大小的 zlib 窗口（wbits = -winBits）压成原始 DEFLATE，再手工包上 gzip 头尾：
动态哈夫曼 · 固定哈夫曼（Z_FIXED）· 存储块（级别 0）· 头部带 FEXTRA、FNAME、FCOMMENT、FHCRC ·
只带 FHCRC · 空 FEXTRA 后跟 FHCRC · 两个手工拼的动态块头（先让 zlib 解一遍，证明拼法本身没错），
其中一个的码长序列用上 16、17、18 三个游程码，而且 16 与 17 的码长不同。
每个有效流的第一个块类型在这里先解析出来核对，确实是想测的那一种才生成。
出错的流：CRC32 改一位（7）· ISIZE 改一位（8）· FLG 保留位（2）· 标识不对（1）· 引用 4164 字节之前的数据，
比最大的 4 KiB 窗口还远（6）· BTYPE 11（3）· NLEN 不互补（4）· 32 个距离码（5，zlib 同样拒）。
另查：第一个用例先不读，等输出缓冲攒满再读走一个字节、紧接着再读，读出 0，不许拿到同一个字节，也不许丢掉下一个；解完之后 isize、crc 两个寄存器对得上。
"""
import json
import pathlib
import random
import struct
import sys
import zlib

out = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".")
out.mkdir(parents=True, exist_ok=True)
cfg = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
label = cfg.get("label", "")
wb = int(cfg.get("knobs", {}).get("winBits", 12))

# 词频按齐普夫分布抽：分布够偏，zlib 才会选动态哈夫曼（一段重复的短句它会选固定码）
WORDS = [b"the", b"of", b"and", b"to", b"in", b"is", b"that", b"for", b"it", b"as", b"with", b"on", b"was",
         b"decoder", b"huffman", b"window", b"literal", b"length", b"distance", b"block", b"stream", b"byte"]
WEIGHTS = [30, 20, 18, 16, 14, 12, 10, 9, 8, 7, 6, 6, 5, 4, 3, 3, 3, 2, 2, 2, 2, 2]
TEXT = b" ".join(random.Random(1952).choices(WORDS, WEIGHTS, k=160))


def raw(data, level, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, -wb, 9, strategy)
    return c.compress(data) + c.flush()


def member(body, data, flg=0, extra=b""):
    head = bytes([0x1F, 0x8B, 8, flg]) + b"\x00\x00\x00\x00" + b"\x00\xff" + extra
    return head + body + struct.pack("<II", zlib.crc32(data), len(data) & 0xFFFFFFFF)


def btype(stream, hdr_len=10):
    return (stream[hdr_len] >> 1) & 3


cases = []   # (名字, 输入字节, 期望输出或 None, 期望错误码)

dyn = raw(TEXT, 9)
if btype(member(dyn, TEXT)) != 2:
    raise SystemExit("动态哈夫曼的用例压出来不是动态块，换文本")
cases.append(("dynamic Huffman", member(dyn, TEXT), TEXT, 0))

fixed = raw(TEXT, 9, zlib.Z_FIXED)
if btype(member(fixed, TEXT)) != 1:
    raise SystemExit("固定哈夫曼的用例压出来不是固定块")
cases.append(("fixed Huffman", member(fixed, TEXT), TEXT, 0))

small = TEXT[:300]
stored = raw(small, 0)
if btype(member(stored, small)) != 0:
    raise SystemExit("级别 0 压出来不是存储块")
cases.append(("stored blocks", member(stored, small), small, 0))

# FEXTRA（XLEN = 4）、FNAME、FCOMMENT、FHCRC 四种可选字段按次序跟在固定头后面
opt = struct.pack("<H", 4) + b"abcd" + b"a.txt\x00" + b"hi\x00"
hdr = bytes([0x1F, 0x8B, 8, 0x1E]) + b"\x00\x00\x00\x00" + b"\x00\xff" + opt
opt += struct.pack("<H", zlib.crc32(hdr) & 0xFFFF)
cases.append(("optional header fields", member(fixed, TEXT, 0x1E, opt), TEXT, 0))

good = member(dyn, TEXT)
bad_crc = bytearray(good); bad_crc[-8] ^= 1
cases.append(("a corrupt CRC32", bytes(bad_crc), None, 7))
bad_size = bytearray(good); bad_size[-4] ^= 1
cases.append(("a corrupt ISIZE", bytes(bad_size), None, 8))
resv = bytearray(good); resv[3] |= 0x20
cases.append(("a reserved FLG bit", bytes(resv), None, 2))
magic = bytearray(good); magic[0] = 0x1E
cases.append(("a wrong ID1", bytes(magic), None, 1))

rnd = random.Random(1951)
head = bytes(rnd.randrange(256) for _ in range(64))
far_data = head + bytes(4100) + head
c = zlib.compressobj(9, zlib.DEFLATED, -15)
far = c.compress(far_data) + c.flush()
cases.append(("a match 4164 bytes back, beyond the window", member(far, far_data), None, 6))

btype3 = bytes([0x1F, 0x8B, 8, 0]) + b"\x00\x00\x00\x00" + b"\x00\xff" + bytes([0x07, 0, 0, 0, 0, 0, 0, 0, 0, 0])
cases.append(("BTYPE 11", btype3, None, 3))

nlen = bytes([0x1F, 0x8B, 8, 0]) + b"\x00\x00\x00\x00" + b"\x00\xff" + bytes([0x01, 3, 0, 0, 0]) + b"abc" + bytes(8)
cases.append(("NLEN that is not the complement of LEN", nlen, None, 4))

# FHCRC 从别的字段后面进来：只带 FHCRC；FEXTRA 的 XLEN 为 0 再跟 FHCRC
alone = bytes([0x1F, 0x8B, 8, 0x02]) + b"\x00\x00\x00\x00" + b"\x00\xff"
cases.append(("FHCRC alone", member(stored, small, 0x02, struct.pack("<H", zlib.crc32(alone) & 0xFFFF)), small, 0))
x0 = struct.pack("<H", 0)
x0hdr = bytes([0x1F, 0x8B, 8, 0x06]) + b"\x00\x00\x00\x00" + b"\x00\xff" + x0
cases.append(("an empty FEXTRA then FHCRC",
              member(stored, small, 0x06, x0 + struct.pack("<H", zlib.crc32(x0hdr) & 0xFFFF)), small, 0))


class Bits:
    def __init__(self):
        self.acc, self.n, self.out = 0, 0, bytearray()

    def put(self, v, k):
        self.acc |= v << self.n
        self.n += k
        while self.n >= 8:
            self.out.append(self.acc & 0xFF)
            self.acc >>= 8
            self.n -= 8

    def huff(self, code, k):   # 哈夫曼码高位先进（RFC 1951 3.1.1）
        self.put(int(f"{code:0{k}b}"[::-1], 2), k)

    def bytes(self):
        return bytes(self.out) + (bytes([self.acc]) if self.n else b"")


CL_ORDER = [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]


def handmade(dist_lens):
    """手工拼一个动态块，只出一个 'A'。码长码 0–15 各 4 位（规范码就是符号本身）；
    字面 0–254 各 8 位（码 0–254），255 与块尾各 9 位（码 510、511）；距离码长由参数给。"""
    lit_lens = [8] * 255 + [9, 9]
    w = Bits()
    w.put(1, 1); w.put(2, 2)
    w.put(len(lit_lens) - 257, 5); w.put(len(dist_lens) - 1, 5); w.put(19 - 4, 4)
    for s in CL_ORDER:
        w.put(4 if s < 16 else 0, 3)
    for n in lit_lens + dist_lens:
        w.huff(n, 4)
    w.huff(ord("A"), 8)
    w.huff(511, 9)
    return w.bytes()


# 30 个距离码（两个 4 位、28 个 5 位，正好完整）zlib 要解得开，先证拼法本身没错；
# 32 个距离码（全 5 位，也完整）格式放得下，zlib 与 puff 都拒，被测件也要拒
hand = handmade([4, 4] + [5] * 28)
if zlib.decompressobj(-15).decompress(hand) != b"A":
    raise SystemExit("手工拼的动态块 zlib 解不开，拼法有错")
over = handmade([5] * 32)
try:
    zlib.decompressobj(-15).decompress(over)
except zlib.error:
    pass
else:
    raise SystemExit("32 个距离码的动态块 zlib 收下了，这个用例测不出东西")
cases.append(("a hand-built dynamic header", member(hand, b"A"), b"A", 0))
cases.append(("32 distance codes", member(over, b"A"), None, 5))


def canon(lens):
    """RFC 1951 3.2.2：按码长给出规范哈夫曼码，{符号: (码, 码长)}。"""
    bl = [0] * 16
    for n in lens:
        if n:
            bl[n] += 1
    code, nxt = 0, [0] * 16
    for b in range(1, 16):
        code = (code + bl[b - 1]) << 1
        nxt[b] = code
    out = {}
    for sym, n in enumerate(lens):
        if n:
            out[sym] = (nxt[n], n)
            nxt[n] += 1
    return out


def handmade_runs():
    """手工拼一个动态块，只出一个 'A'。码长码只用 4、5、7、16、17、18，码长 7:2、16:2、17:3、18:3、4:3、5:3（完整）。
    字面 0–63 不用（18 补 64 个零）、64–190 与块尾各 7 位（一个 7 之后 16 重复 21 次）、191–200 不用（17 补 10 个零）、
    201–255 不用（18 补 55 个零）；距离码 [4, 4] + [5] × 28（一个 5 之后 16 补 27 个）。
    码长字母表次序里 16 与 17 对调，解码器就给这两个游程码配错码。"""
    cl = [0] * 19
    for sym, n in {7: 2, 16: 2, 17: 3, 18: 3, 4: 3, 5: 3}.items():
        cl[sym] = n
    lit = [0] * 64 + [7] * 127 + [0] * 65 + [7]
    dist = [4, 4] + [5] * 28
    runs = ([(18, 53, 7), (7, 0, 0)] + [(16, 3, 2)] * 21 + [(17, 7, 3), (18, 44, 7), (7, 0, 0),
            (4, 0, 0), (4, 0, 0), (5, 0, 0)] + [(16, 3, 2)] * 4 + [(16, 0, 2)])
    cc, lc = canon(cl), canon(lit)
    w = Bits()
    w.put(1, 1); w.put(2, 2)
    w.put(len(lit) - 257, 5); w.put(len(dist) - 1, 5); w.put(19 - 4, 4)
    for sym in CL_ORDER:
        w.put(cl[sym], 3)
    for sym, extra, k in runs:
        w.huff(*cc[sym])
        if k:
            w.put(extra, k)
    w.huff(*lc[ord("A")])
    w.huff(*lc[256])
    return w.bytes()


runs = handmade_runs()
if zlib.decompressobj(-15).decompress(runs) != b"A":
    raise SystemExit("用上 16、17、18 的手工动态块 zlib 解不开，拼法有错")
cases.append(("a dynamic header using code-length codes 16, 17 and 18", member(runs, b"A"), b"A", 0))

# 每个用例的输入与期望输出各拼成一串，按偏移查
ins, outs, table = bytearray(), bytearray(), []
for name, data, expect, err in cases:
    table.append((name, len(ins), len(data), len(outs), len(expect) if expect else 0, err,
                  zlib.crc32(expect) if expect else 0))
    ins += data
    if expect:
        outs += expect


def rom(fn, blob, width):
    body = "\n".join(f"      {i}: return 8'h{b:02X};" for i, b in enumerate(blob))
    return (f"  function Bit#(8) {fn}(UInt#({width}) i);\n    case (i)\n{body}\n"
            f"      default: return 0;\n    endcase\n  endfunction\n")


steps = []
for k, (name, i0, n, o0, m, err, crc) in enumerate(table):
    steps.append(f"""    // {name}
    action cur <= {k}; inAt <= {i0}; inEnd <= {i0 + n}; outAt <= {o0}; outEnd <= {o0 + m}; pokeAt <= {(i0 + 100) if k == 0 else 65535}; endaction
    wr(8'h00, 1);
    run;
    action
      Bool wrong = False;
      if (stErr != {err}) begin $display("FAIL {name}: error code %0d, want {err}", stErr); wrong = True; end
      if ({err} == 0 && !stDone) begin $display("FAIL {name}: the decoder never reported done"); wrong = True; end
      if ({err} == 0 && outAt != {o0 + m}) begin $display("FAIL {name}: %0d of {m} bytes came out", outAt - {o0}); wrong = True; end
      if (mismatch) begin $display("FAIL {name}: output byte %0d is %02h, want %02h", badAt - {o0}, badGot, outByte(badAt)); wrong = True; end
      if (wrong) bad <= True;
      mismatch <= False;
    endaction""")
    if err == 0:
        steps.append(f"""    rd(8'h10);
    rd2(8'h14);
    action
      if (rdv != {m} || rdv2 != 32'h{crc:08X}) begin $display("FAIL {name}: isize %0d crc %08h, want {m} and {crc:08x}", rdv, rdv2); bad <= True; end
    endaction""")

verdict = (f"with a {2**wb}-byte window, dynamic, fixed and stored blocks, two hand-built dynamic headers (one using code-length codes 16, 17 and 18) and three "
           f"combinations of optional header fields decode byte for byte against zlib with matching isize and crc, "
           f"reading dout again right after taking a byte from a full output buffer neither repeats it nor loses the next one, writing only the interrupt enable mid-stream does not restart the decoder, "
           f"and a corrupt CRC32, a corrupt ISIZE, a reserved flag, a wrong ID1, "
           f"a match beyond the window, BTYPE 11, a bad NLEN and 32 distance codes each report their own error code")

TEMPLATE = r'''package Gzip@L@Tb;

// 由 htest/mkgziptb.py 生成，勿手改。这一点：winBits=@WB@，@NCASES@ 个用例

import StmtFSM::*;
import RegIf::*;
import Gzip::*;

(* synthesize *)
module mkGzip@L@Tb(Empty);
  GzipIfc#(8, 32, @WB@) d <- mkGzip(GzipCfg { none: ? });

@INROM@
@OUTROM@
  Reg#(UInt#(8))  cur      <- mkReg(0);
  Reg#(UInt#(16)) inAt     <- mkReg(0);
  Reg#(UInt#(16)) inEnd    <- mkReg(0);
  Reg#(UInt#(16)) outAt    <- mkReg(0);
  Reg#(UInt#(16)) outEnd   <- mkReg(0);
  Reg#(Bool)      stDone   <- mkReg(False);
  Reg#(UInt#(4))  stErr    <- mkReg(0);
  Reg#(Bool)      mismatch <- mkReg(False);
  Reg#(UInt#(16)) badAt    <- mkReg(0);
  Reg#(Bit#(8))   badGot   <- mkReg(0);
  Reg#(Bool)      bad      <- mkReg(False);
  Reg#(Bool)      twice    <- mkReg(False);
  Reg#(Bit#(32))  rdv      <- mkReg(0);
  Reg#(Bit#(32))  rdv2     <- mkReg(0);
  Reg#(UInt#(32)) guard    <- mkReg(0);
  Reg#(UInt#(16)) pokeAt   <- mkReg(16'hFFFF);

  function Action wr(Bit#(8) a, Bit#(32) v) = action
    let x <- d.regs.access(RegReq { addr: a, write: True, wdata: v, wstrb: 4'hF });
  endaction;
  function Action rd(Bit#(8) a) = action
    let x <- d.regs.access(RegReq { addr: a, write: False, wdata: 0, wstrb: 4'hF });
    rdv <= x.rdata;
  endaction;
  function Action rd2(Bit#(8) a) = action
    let x <- d.regs.access(RegReq { addr: a, write: False, wdata: 0, wstrb: 4'hF });
    rdv2 <= x.rdata;
  endaction;

  // 一拍一次总线访问：读状态；有空位就喂一个字节，有字节就读一个，二者轮着来
  Reg#(Bool) feedTurn <- mkReg(True);
  Reg#(Bool) checkTwice <- mkReg(True);
  // 第一个用例先不读，等输出缓冲攒满（有字节摆着、输入也收不下了）才开始取；只有这样紧接着的那一次再读
  // 才有第二个字节可丢。缓冲只剩一个字节时，多记一次取走也什么都不会少
  Reg#(Bool) hold <- mkReg(True);

  Stmt run = seq
    action stDone <= False; stErr <= 0; guard <= 0; endaction
    while (!stDone && stErr == 0 && guard < 400000) seq
      action
        let s <- d.regs.access(RegReq { addr: 8'h04, write: False, wdata: 0, wstrb: 4'hF });
        stDone <= s.rdata[1] == 1;
        stErr  <= unpack(s.rdata[7:4]);
        rdv    <= s.rdata;
        guard  <= guard + 1;
      endaction
      if (hold && rdv[3] == 1 && (rdv[2] == 0 || inAt == inEnd)) action
        hold <= False;
      endaction
      else if (!hold && rdv[3] == 1 && (!feedTurn || rdv[2] == 0 || inAt == inEnd)) seq
        action
          let x <- d.regs.access(RegReq { addr: 8'h0C, write: False, wdata: 0, wstrb: 4'hF });
          if (outAt < outEnd && x.rdata[7:0] != outByte(outAt) && !mismatch) begin
            mismatch <= True; badAt <= outAt; badGot <= x.rdata[7:0];
          end
          outAt <= outAt + 1;
          feedTurn <= True;
        endaction
        // 读走之后下一拍紧接着再读一次（只查一回，缓冲是满的）：读出的必须是 0，也不许因为这一读丢掉下一个字节
        if (checkTwice) action
          let x <- d.regs.access(RegReq { addr: 8'h0C, write: False, wdata: 0, wstrb: 4'hF });
          if (x.rdata != 0) twice <= True;
          checkTwice <= False;
        endaction
      endseq
      else if (inAt == pokeAt) action
        // 解到一半只写中断使能：start 位是 0，解码器不许重来
        wr(8'h00, 2);
        pokeAt <= 16'hFFFF;
      endaction
      else if (rdv[2] == 1 && inAt < inEnd) action
        wr(8'h08, zeroExtend(inByte(inAt)));
        inAt <= inAt + 1;
        feedTurn <= False;
      endaction
    endseq
    if (guard >= 400000) action $display("FAIL case %0d never finished", cur); bad <= True; endaction
  endseq;

  Stmt test = seq
@STEPS@
    action if (twice) begin $display("FAIL reading dout again right after taking a byte gave a byte, it was delivered twice"); bad <= True; end endaction
  endseq;

  FSM fsm <- mkFSM(test);
  Reg#(Bool) started <- mkReg(False);

  rule go (!started);
    started <= True;
    fsm.start;
  endrule

  rule fin (started && fsm.done);
    if (bad) $display("FAILED");
    else $display("PASS gzip: @VERDICT@");
    $finish(bad ? 1 : 0);
  endrule
endmodule

endpackage
'''

txt = (TEMPLATE.replace("@L@", label).replace("@WB@", str(wb)).replace("@NCASES@", str(len(cases)))
       .replace("@INROM@", rom("inByte", ins, 16)).replace("@OUTROM@", rom("outByte", outs, 16))
       .replace("@STEPS@", "\n".join(steps)).replace("@VERDICT@", verdict))

(out / f"Gzip{label}Tb.bsv").write_text(txt, encoding="utf-8")
print(f"  gzip 行为测试台就位：winBits={wb}，{len(cases)} 个用例，输入 {len(ins)} 字节，期望输出 {len(outs)} 字节")
