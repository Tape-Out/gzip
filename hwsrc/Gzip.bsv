package Gzip;

// gzip 解压（RFC 1952 的一个成员，里面是 RFC 1951 的 DEFLATE）。字节经寄存器一个一个喂进来，
// 解出来的字节一个一个读走。常数表在 Deflate（BH），CRC-32 用 hwcore 的 Gf2。
// 规范哈夫曼的建表与逐位解码照 zlib contrib/puff 的 construct 与 decode 的算法写：
//   建表：按码长计数 → 查超额与不完整 → 算每个码长在符号表里的起点 → 按码长、码长内按符号次序排好
//   解码：一拍一位，code 累加到第 len 位时若 code < first + count 就命中，否则进到下一个码长
// 状态只有 step 一条规则写；写进来的字节、读走的脉冲、start 脉冲都在总线方法之后才有，由 CReg 递到下一拍。

import Vector::*;
import RegFile::*;
import RegIf::*;
import GzipRegs::*;
import Deflate::*;
import Gf2::*;

typedef struct {
  Bit#(0) none;
} GzipCfg;

interface GzipIfc#(numeric type aw, numeric type dw, numeric type winBits);
  interface RegIf#(aw, dw) regs;
  (* always_ready *) method Bool irq;
endinterface

typedef enum {
  Idle, Id1, Id2, Cm, Flg, Skip6, XlenLo, XlenHi, SkipExtra, Name, Comment, SkipHcrc,
  BlkHdr, StAlign, StLen, StNlen, StCopy,
  DynHdr, ClLens, Build, DecCl, RepBits, RepFill,
  DecLit, LenBits, DecDist, DistBits, Copy,
  TrAlign, TrCrcLo, TrCrcHi, TrSizeLo, TrSizeHi, Done, Fail
} Ph deriving (Bits, Eq);

// 建表做完之后去哪
typedef enum { ToDecCl, ToDist, ToDecLit } After deriving (Bits, Eq);

module mkGzip#(GzipCfg cfg)(GzipIfc#(aw, dw, winBits))
    provisos (Mul#(TDiv#(dw, 8), 8, dw), Add#(_a, 8, aw), Add#(_b, 1, dw),
              Add#(_c, 4, dw), Add#(_d, 8, dw), Add#(_e, 32, dw),
              Add#(_f, winBits, 16));

  GzipRegsIfc#(aw, dw) r <- mkGzipRegs;

  Integer winSize = 2 ** valueOf(winBits);

  Reg#(Maybe#(Bit#(8))) inPend[2] <- mkCReg(2, tagged Invalid);
  Reg#(Bool)            take[2]   <- mkCReg(2, False);
  Reg#(Bool)            startP[2] <- mkCReg(2, False);

  // 输入、输出各一个四格环形缓冲，都只归 step 写
  Vector#(4, Reg#(Bit#(8))) inBuf   <- replicateM(mkReg(0));
  Reg#(UInt#(2))            inHead  <- mkReg(0);
  Reg#(UInt#(3))            inCnt   <- mkReg(0);
  Vector#(4, Reg#(Bit#(8))) outBuf  <- replicateM(mkReg(0));
  Reg#(UInt#(2))            outHead <- mkReg(0);
  Reg#(UInt#(3))            outCnt  <- mkReg(0);

  // 读位器：低位先出（RFC 1951 3.1.1）
  Reg#(Bit#(32)) bitbuf <- mkReg(0);
  Reg#(UInt#(6)) bitcnt <- mkReg(0);

  Reg#(Ph)       ph      <- mkReg(Idle);
  Reg#(UInt#(4)) errCode <- mkReg(0);
  Reg#(Bit#(8))  flg     <- mkReg(0);
  Reg#(UInt#(16)) cnt16  <- mkReg(0);
  Reg#(Bool)     bfinal  <- mkReg(False);
  Reg#(Bool)     fixedM  <- mkReg(False);
  Reg#(Bit#(16)) crcLo   <- mkReg(0);

  // 动态块头
  Reg#(UInt#(9))  hlit   <- mkReg(0);
  Reg#(UInt#(6))  hdist  <- mkReg(0);
  Reg#(UInt#(5))  hclen  <- mkReg(0);
  Reg#(UInt#(9))  li     <- mkReg(0);
  Reg#(UInt#(8))  rep    <- mkReg(0);
  Reg#(UInt#(4))  repVal <- mkReg(0);
  Reg#(UInt#(2))  repExt <- mkReg(0);   // 0: 16（2 位）· 1: 17（3 位）· 2: 18（7 位）

  // 三张哈夫曼表：0 码长码、1 字面/长度、2 距离
  Vector#(19, Reg#(UInt#(3)))  cll    <- replicateM(mkReg(0));
  RegFile#(UInt#(9), UInt#(4)) lens   <- mkRegFile(0, 319);
  Vector#(16, Reg#(UInt#(9)))  clCnt  <- replicateM(mkReg(0));
  Vector#(16, Reg#(UInt#(9)))  llCnt  <- replicateM(mkReg(0));
  Vector#(16, Reg#(UInt#(9)))  dCnt   <- replicateM(mkReg(0));
  RegFile#(UInt#(5), UInt#(9)) clSym  <- mkRegFile(0, 18);
  RegFile#(UInt#(9), UInt#(9)) llSym  <- mkRegFile(0, 287);
  RegFile#(UInt#(5), UInt#(9)) dSym   <- mkRegFile(0, 29);
  Vector#(16, Reg#(UInt#(9)))  offs   <- replicateM(mkReg(0));

  // 建表
  Reg#(UInt#(2)) tsel  <- mkReg(0);
  Reg#(UInt#(2)) bstep <- mkReg(0);
  Reg#(UInt#(9)) bsym  <- mkReg(0);
  Reg#(UInt#(9)) bn    <- mkReg(0);
  Reg#(After)    after <- mkReg(ToDecCl);

  // 逐位解码
  Reg#(UInt#(16)) code  <- mkReg(0);
  Reg#(UInt#(16)) first <- mkReg(0);
  Reg#(UInt#(9))  index <- mkReg(0);
  Reg#(UInt#(5))  hlen  <- mkReg(1);

  // 拷贝与窗口
  Reg#(UInt#(9))                      mlen <- mkReg(0);
  Reg#(UInt#(16))                     mdist <- mkReg(0);
  Reg#(UInt#(5))                      msym <- mkReg(0);
  RegFile#(Bit#(winBits), Bit#(8))    win  <- mkRegFileFull;
  Reg#(Bit#(winBits))                 wp   <- mkReg(0);
  Reg#(UInt#(32))                     produced <- mkReg(0);
  Reg#(Bit#(32))                      crcR <- mkReg(crc32IsoHdlc.seed);

  Bool decoding = ph != Idle && ph != Done && ph != Fail;
  Bool offer    = outCnt > 0 && !take[0];
  // mark 写 CReg 的 1 口，排在 step 之后，不能再读 step 写的寄存器；这一拍摆没摆字节由 show 递过去
  PulseWire offered <- mkPulseWire;

  // 读 dout 只在那一拍确实有字节摆着时才算取走：没字节时读出 0，脉冲不许把下一拍才到的字节丢掉
  rule mark;
    if (r.din_wr) inPend[1] <= tagged Valid r.din_wr_val;
    if (r.dout_rd && offered) take[1] <= True;
    // swmod 是「ctrl 被写过」：只写中断使能时 start 位是 0，不许重来
    if (r.ctrl_start_wr && r.ctrl_start_wr_val == 1) startP[1] <= True;
  endrule

  function UInt#(4) lenAt(UInt#(2) t, UInt#(9) s);
    if (t == 0) return zeroExtend(cll[s]);
    else if (fixedM) return t == 1 ? fixedLenTab[s] : 5;
    else return lens.sub(t == 2 ? hlit + s : s);
  endfunction

  function UInt#(9) countOf(UInt#(2) t, UInt#(5) l) =
    t == 0 ? clCnt[l] : (t == 1 ? llCnt[l] : dCnt[l]);

  function UInt#(9) symbolOf(UInt#(2) t, UInt#(9) i) =
    t == 0 ? clSym.sub(truncate(i)) : (t == 1 ? llSym.sub(i) : dSym.sub(truncate(i)));

  rule step;
    // ---- 这一拍的所有新值先攒在局部变量里 ----
    Ph        nph   = ph;
    UInt#(4)  nerr  = errCode;
    UInt#(6)  used  = 0;
    Maybe#(Bit#(8)) emit = tagged Invalid;

    UInt#(16) ncode  = code;
    UInt#(16) nfirst = first;
    UInt#(9)  nindex = index;
    UInt#(5)  nhlen  = hlen;
    Bool      symHit = False;
    UInt#(9)  sym    = 0;

    UInt#(2) dsel = (ph == DecCl) ? 0 : ((ph == DecDist) ? 2 : 1);
    Bool roomOut = outCnt < 3;

    // 规范哈夫曼逐位解码的一步（DecCl、DecLit、DecDist 共用）
    if ((ph == DecCl || ph == DecLit || ph == DecDist) && bitcnt >= 1 && roomOut) begin
      UInt#(16) c   = code | zeroExtend(unpack(bitbuf[0]));
      UInt#(9)  cnt = countOf(dsel, hlen);
      used = 1;
      if (c < first + zeroExtend(cnt)) begin
        symHit = True;
        sym = symbolOf(dsel, index + truncate(c - first));
        ncode = 0; nfirst = 0; nindex = 0; nhlen = 1;
      end else if (hlen == 15) begin
        nph = Fail; nerr = 5;
      end else begin
        nindex = index + cnt;
        nfirst = (first + zeroExtend(cnt)) << 1;
        ncode  = c << 1;
        nhlen  = hlen + 1;
      end
    end

    Bit#(8) b8 = bitbuf[7:0];

    if (startP[0]) begin
      // 上一个流可能停在解码半途：逐位解码的状态一起清
      nph = Id1; nerr = 0;
      ncode = 0; nfirst = 0; nindex = 0; nhlen = 1;
    end else case (ph)
      // ---- gzip 头（RFC 1952 2.3.1）----
      Id1: if (bitcnt >= 8) begin used = 8; if (b8 != 8'h1f) begin nph = Fail; nerr = 1; end else nph = Id2; end
      Id2: if (bitcnt >= 8) begin used = 8; if (b8 != 8'h8b) begin nph = Fail; nerr = 1; end else nph = Cm; end
      Cm:  if (bitcnt >= 8) begin used = 8; if (b8 != 8)     begin nph = Fail; nerr = 1; end else nph = Flg; end
      Flg: if (bitcnt >= 8) begin
             used = 8;
             flg <= b8;
             // 保留位非零必须报错（2.3.1.2）
             if (b8[7:5] != 0) begin nph = Fail; nerr = 2; end
             else begin nph = Skip6; cnt16 <= 6; end
           end
      Skip6: if (bitcnt >= 8) begin
               used = 8;
               if (cnt16 == 1) nph = flg[2] == 1 ? XlenLo : (flg[3] == 1 ? Name : (flg[4] == 1 ? Comment : (flg[1] == 1 ? SkipHcrc : BlkHdr)));
               cnt16 <= cnt16 - 1;
             end
      XlenLo: if (bitcnt >= 8) begin used = 8; cnt16 <= zeroExtend(unpack(b8)); nph = XlenHi; end
      XlenHi: if (bitcnt >= 8) begin
                used = 8;
                UInt#(16) x = cnt16 | (zeroExtend(unpack(b8)) << 8);
                cnt16 <= x;
                nph = x == 0 ? (flg[3] == 1 ? Name : (flg[4] == 1 ? Comment : (flg[1] == 1 ? SkipHcrc : BlkHdr))) : SkipExtra;
              end
      SkipExtra: if (bitcnt >= 8) begin
                   used = 8;
                   if (cnt16 == 1) nph = flg[3] == 1 ? Name : (flg[4] == 1 ? Comment : (flg[1] == 1 ? SkipHcrc : BlkHdr));
                   cnt16 <= cnt16 - 1;
                 end
      Name: if (bitcnt >= 8) begin
              used = 8;
              if (b8 == 0) nph = flg[4] == 1 ? Comment : (flg[1] == 1 ? SkipHcrc : BlkHdr);
            end
      Comment: if (bitcnt >= 8) begin
                 used = 8;
                 if (b8 == 0) nph = flg[1] == 1 ? SkipHcrc : BlkHdr;
               end
      // 从 Skip6、XlenHi、SkipExtra、Name、Comment 哪一处进来都有可能，cnt16 的余数靠不住，两个字节一次吃掉
      SkipHcrc: if (bitcnt >= 16) begin used = 16; nph = BlkHdr; end

      // ---- 块头（RFC 1951 3.2.3）----
      BlkHdr: if (bitcnt >= 3) begin
                used = 3;
                bfinal <= bitbuf[0] == 1;
                case (bitbuf[2:1])
                  2'b00: nph = StAlign;
                  2'b01: begin fixedM <= True; tsel <= 1; bstep <= 0; bn <= 288; after <= ToDist; nph = Build; end
                  2'b10: nph = DynHdr;
                  default: begin nph = Fail; nerr = 3; end
                endcase
              end

      // ---- 存储块（3.2.4）：丢到字节边界，LEN 与 NLEN 必须互补 ----
      StAlign: begin used = zeroExtend(bitcnt % 8); nph = StLen; end
      StLen:   if (bitcnt >= 16) begin used = 16; cnt16 <= unpack(bitbuf[15:0]); nph = StNlen; end
      StNlen:  if (bitcnt >= 16) begin
                 used = 16;
                 if (bitbuf[15:0] != ~pack(cnt16)) begin nph = Fail; nerr = 4; end
                 else nph = cnt16 == 0 ? (bfinal ? TrAlign : BlkHdr) : StCopy;
               end
      StCopy: if (bitcnt >= 8 && roomOut) begin
                used = 8;
                emit = tagged Valid b8;
                if (cnt16 == 1) nph = bfinal ? TrAlign : BlkHdr;
                cnt16 <= cnt16 - 1;
              end

      // ---- 动态块头（3.2.7）----
      DynHdr: if (bitcnt >= 14) begin
                used = 14;
                hlit  <= 257 + zeroExtend(unpack(bitbuf[4:0]));
                hdist <= 1 + zeroExtend(unpack(bitbuf[9:5]));
                hclen <= 4 + zeroExtend(unpack(bitbuf[13:10]));
                for (Integer i = 0; i < 19; i = i + 1) cll[i] <= 0;
                cnt16 <= 0;
                fixedM <= False;
                // 照 puff 的 MAXLCODES、MAXDCODES（286、30）拒多出来的码长；距离码超过 30 个还会写出 dSym 的范围
                if (bitbuf[4:0] > 29 || bitbuf[9:5] > 29) begin nph = Fail; nerr = 5; end
                else nph = ClLens;
              end
      ClLens: if (bitcnt >= 3) begin
                used = 3;
                cll[clOrderTab[cnt16]] <= unpack(bitbuf[2:0]);
                if (cnt16 + 1 == zeroExtend(hclen)) begin
                  tsel <= 0; bstep <= 0; bn <= 19; after <= ToDecCl; nph = Build;
                end
                cnt16 <= cnt16 + 1;
              end

      // ---- 建表（照 puff 的 construct）----
      Build: case (bstep)
               0: begin
                    for (Integer l = 0; l < 16; l = l + 1) begin
                      if (tsel == 0) clCnt[l] <= 0;
                      else if (tsel == 1) llCnt[l] <= 0;
                      else dCnt[l] <= 0;
                    end
                    bsym <= 0; bstep <= 1;
                  end
               1: begin
                    UInt#(4) l = lenAt(tsel, bsym);
                    UInt#(9) v = countOf(tsel, zeroExtend(l)) + 1;
                    if (tsel == 0) clCnt[l] <= v;
                    else if (tsel == 1) llCnt[l] <= v;
                    else dCnt[l] <= v;
                    if (bsym + 1 == bn) bstep <= 2;
                    bsym <= bsym + 1;
                  end
               2: begin
                    // 超额一律非法；不完整只容忍「码长只有 0 与 1」的字面/长度或距离码集（puff 同此），
                    // 码长码必须完整；固定哈夫曼的距离码本来就不完整，不查
                    Int#(18) left = 1;
                    Bool over = False;
                    for (Integer l = 1; l < 16; l = l + 1) begin
                      left = (left << 1) - unpack(zeroExtend(pack(countOf(tsel, fromInteger(l)))));
                      if (left < 0) over = True;
                    end
                    Bool onlyShort = countOf(tsel, 0) + countOf(tsel, 1) == bn;
                    Bool bad = over || (left > 0 && !fixedM && (tsel == 0 || !onlyShort));
                    UInt#(9) o = 0;
                    for (Integer l = 1; l < 16; l = l + 1) begin
                      offs[l] <= o;
                      o = o + countOf(tsel, fromInteger(l));
                    end
                    if (bad) begin nph = Fail; nerr = 5; end
                    else begin bsym <= 0; bstep <= 3; end
                  end
               3: begin
                    UInt#(4) l = lenAt(tsel, bsym);
                    if (l != 0) begin
                      UInt#(9) at = offs[l];
                      if (tsel == 0) clSym.upd(truncate(at), bsym);
                      else if (tsel == 1) llSym.upd(at, bsym);
                      else dSym.upd(truncate(at), bsym);
                      offs[l] <= at + 1;
                    end
                    if (bsym + 1 == bn) begin
                      case (after)
                        ToDecCl:  begin li <= 0; nph = DecCl; end
                        ToDist:   begin tsel <= 2; bstep <= 0; bn <= fixedM ? 30 : zeroExtend(hdist); after <= ToDecLit; end
                        ToDecLit: nph = DecLit;
                      endcase
                    end
                    bsym <= bsym + 1;
                  end
             endcase

      // ---- 码长序列（3.2.7）----
      DecCl: if (symHit) begin
               UInt#(9) total = hlit + zeroExtend(hdist);
               if (sym < 16) begin
                 lens.upd(li, truncate(sym));
                 if (li + 1 == total) begin tsel <= 1; bstep <= 0; bn <= hlit; after <= ToDist; nph = Build; end
                 li <= li + 1;
               end else if (sym == 16 && li == 0) begin
                 nph = Fail; nerr = 5;
               end else begin
                 repExt <= truncate(sym - 16);
                 repVal <= sym == 16 ? lens.sub(li - 1) : 0;
                 nph = RepBits;
               end
             end
      RepBits: begin
                 UInt#(6) needU = repExt == 0 ? 2 : (repExt == 1 ? 3 : 7);
                 if (bitcnt >= needU) begin
                   used = needU;
                   UInt#(8) extra = unpack(bitbuf[7:0]) & ((repExt == 0) ? 3 : ((repExt == 1) ? 7 : 127));
                   UInt#(8) n = extra + ((repExt == 2) ? 11 : 3);
                   UInt#(10) upto  = zeroExtend(li) + zeroExtend(n);
                   UInt#(10) total = zeroExtend(hlit) + zeroExtend(hdist);
                   if (upto > total) begin nph = Fail; nerr = 5; end
                   else begin rep <= n; nph = RepFill; end
                 end
               end
      RepFill: begin
                 UInt#(9) total = hlit + zeroExtend(hdist);
                 lens.upd(li, repVal);
                 li <= li + 1;
                 rep <= rep - 1;
                 if (rep == 1) begin
                   if (li + 1 == total) begin tsel <= 1; bstep <= 0; bn <= hlit; after <= ToDist; nph = Build; end
                   else nph = DecCl;
                 end
               end

      // ---- 压缩数据（3.2.5）----
      DecLit: if (symHit) begin
                if (sym < 256) emit = tagged Valid truncate(pack(sym));
                else if (sym == 256) nph = bfinal ? TrAlign : BlkHdr;
                else if (sym <= 285) begin msym <= truncate(sym - 257); nph = LenBits; end
                else begin nph = Fail; nerr = 5; end
              end
      LenBits: begin
                 UInt#(3) e = lenExtraTab[msym];
                 if (bitcnt >= zeroExtend(e)) begin
                   used = zeroExtend(e);
                   Bit#(32) m = (32'h1 << e) - 1;
                   mlen <= lenBaseTab[msym] + unpack(truncate(bitbuf & m));
                   nph = DecDist;
                 end
               end
      DecDist: if (symHit) begin
                 if (sym <= 29) begin msym <= truncate(sym); nph = DistBits; end
                 else begin nph = Fail; nerr = 5; end
               end
      DistBits: begin
                  UInt#(4) e = distExtraTab[msym];
                  if (bitcnt >= zeroExtend(e)) begin
                    used = zeroExtend(e);
                    Bit#(32) m = (32'h1 << e) - 1;
                    UInt#(16) d = distBaseTab[msym] + unpack(truncate(bitbuf & m));
                    // 引用不许越过已经解出来的字节，也不许越过窗口
                    UInt#(32) dd = zeroExtend(d);
                    if (dd > produced || dd > fromInteger(winSize)) begin nph = Fail; nerr = 6; end
                    else begin mdist <= d; nph = Copy; end
                  end
                end
      Copy: if (roomOut) begin
              Bit#(winBits) from = wp - truncate(pack(mdist));
              emit = tagged Valid win.sub(from);
              if (mlen == 1) nph = DecLit;
              mlen <= mlen - 1;
            end

      // ---- gzip 尾（RFC 1952 2.3.1）----
      TrAlign:  begin used = zeroExtend(bitcnt % 8); nph = TrCrcLo; end
      TrCrcLo:  if (bitcnt >= 16) begin used = 16; crcLo <= bitbuf[15:0]; nph = TrCrcHi; end
      TrCrcHi:  if (bitcnt >= 16) begin
                  used = 16;
                  if ({bitbuf[15:0], crcLo} != crcFinal(crc32IsoHdlc, crcR)) begin nph = Fail; nerr = 7; end
                  else nph = TrSizeLo;
                end
      TrSizeLo: if (bitcnt >= 16) begin used = 16; crcLo <= bitbuf[15:0]; nph = TrSizeHi; end
      TrSizeHi: if (bitcnt >= 16) begin
                  used = 16;
                  if ({bitbuf[15:0], crcLo} != pack(produced)) begin nph = Fail; nerr = 8; end
                  else nph = Done;
                end
      default: noAction;
    endcase

    // ---- 读位器：先吃掉用过的位，再从输入缓冲补一个字节 ----
    Bit#(32) nbuf = bitbuf >> used;
    UInt#(6) ncnt = bitcnt - used;
    UInt#(2) nInHead = inHead;
    UInt#(3) nInCnt  = inCnt;
    if (startP[0]) begin
      nbuf = 0; ncnt = 0; nInHead = 0; nInCnt = 0;
    end else if (ncnt <= 24 && inCnt > 0 && nph != Idle && nph != Done && nph != Fail) begin
      nbuf = nbuf | (zeroExtend(inBuf[inHead]) << ncnt);
      ncnt = ncnt + 8;
      nInHead = inHead + 1;
      nInCnt = nInCnt - 1;
    end
    if (inPend[0] matches tagged Valid .b &&& inCnt < 4 &&& !startP[0]) begin
      inBuf[inHead + truncate(inCnt)] <= b;
      nInCnt = nInCnt + 1;
    end

    // ---- 输出：写窗口、算 CRC、进输出缓冲；读走的出队 ----
    UInt#(2)  nOutHead = outHead;
    UInt#(3)  nOutCnt  = outCnt;
    Bit#(winBits) nwp  = wp;
    UInt#(32) nprod    = produced;
    Bit#(32)  ncrc     = crcR;
    if (take[0] && outCnt > 0) begin nOutHead = outHead + 1; nOutCnt = nOutCnt - 1; end
    if (startP[0]) begin
      nOutHead = 0; nOutCnt = 0; nwp = 0; nprod = 0; ncrc = crc32IsoHdlc.seed;
    end else if (emit matches tagged Valid .e) begin
      outBuf[outHead + truncate(outCnt)] <= e;
      nOutCnt = nOutCnt + 1;
      win.upd(wp, e);
      nwp = wp + 1;
      nprod = produced + 1;
      ncrc = crcByte(crc32IsoHdlc, crcR, e);
    end

    inPend[0] <= tagged Invalid;
    take[0]   <= False;
    startP[0] <= False;
    ph <= nph; errCode <= nerr;
    code <= ncode; first <= nfirst; index <= nindex; hlen <= nhlen;
    bitbuf <= nbuf; bitcnt <= ncnt; inHead <= nInHead; inCnt <= nInCnt;
    outHead <= nOutHead; outCnt <= nOutCnt; wp <= nwp; produced <= nprod; crcR <= ncrc;
  endrule

  rule show;
    r.status_busy_in(decoding ? 1 : 0);
    r.status_done_in(ph == Done ? 1 : 0);
    r.status_inready_in((decoding && inCnt < 3 && !isValid(inPend[0])) ? 1 : 0);
    if (offer) offered.send;
    r.status_outvalid_in(offer ? 1 : 0);
    r.status_err_in(pack(errCode));
    r.dout_in(offer ? outBuf[outHead] : 0);
    r.isize_in(pack(produced));
    r.crc_in(crcFinal(crc32IsoHdlc, crcR));
  endrule

  interface regs = r.regs;
  method Bool irq = r.ctrl_ien == 1 && (ph == Done || ph == Fail);
endmodule

endpackage
