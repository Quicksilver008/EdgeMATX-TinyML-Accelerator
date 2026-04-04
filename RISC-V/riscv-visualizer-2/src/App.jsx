import React, { useState, useEffect } from 'react';

// --- Execution Stages Narrative ---
const STAGES = [
  {
    id: 'idle',
    title: 'Idle / Standard Execution',
    description: 'CPU runs standard RV32I instructions. The PCPI wrapper is in S_IDLE. Data Memory is accessed normally via the standard EX_MEM pipeline register.',
    activePaths: ['pc_to_imem', 'pc_to_adder', 'adder_to_mux', 'imem_to_ifid', 'ifid_to_ctrl', 'ifid_to_reg_rs1', 'ifid_to_reg_rs2', 'ifid_to_imm', 'ctrl_to_idex', 'reg_to_idex_rs1', 'reg_to_idex_rs2', 'imm_to_idex', 'idex_to_muxA', 'idex_to_muxB', 'idex_to_muxB_imm', 'idex_to_aluctrl', 'muxA_to_alu', 'muxB_to_alu', 'aluctrl_to_alu', 'alu_to_exmem', 'idex_to_exmem_rs2', 'exmem_to_dmem_addr', 'exmem_to_dmem_data', 'exmem_to_memwb_alu', 'dmem_to_memwb', 'memwb_to_mux_data', 'memwb_to_mux_alu', 'mux_to_regfile'],
    wrapperState: 'S_IDLE'
  },
  {
    id: 'fetch_decode',
    title: '1. Fetch & Decode custom-0',
    description: 'CPU fetches 0x5420818b. The ID stage Control Unit decodes custom-0. Base pointers rs1 (Matrix A) and rs2 (Matrix B) are read from the Register File.',
    activePaths: ['pc_to_imem', 'imem_to_ifid', 'ifid_to_ctrl', 'ifid_to_reg_rs1', 'ifid_to_reg_rs2', 'reg_to_idex_rs1', 'reg_to_idex_rs2', 'ctrl_to_idex'],
    wrapperState: 'S_IDLE'
  },
  {
    id: 'issue_stall',
    title: '2. PCPI Issue & Stall (ID/EX)',
    description: 'The ID_EX register passes rs1/rs2 to the PCPI Wrapper. The Wrapper transitions to S_LOAD_A and asserts pcpi_wait, freezing the PC, IF_ID, and ID_EX registers via Hazard Detection logic.',
    activePaths: ['ctrl_to_idex', 'reg_to_idex_rs1', 'reg_to_idex_rs2', 'idex_to_accel_valid', 'idex_to_accel_rs1', 'idex_to_accel_rs2', 'accel_stall_fb', 'accel_stall_ifid', 'accel_stall_idex', 'accel_stall_hazard'],
    wrapperState: 'S_IDLE -> S_LOAD_A'
  },
  {
    id: 'dma_read',
    title: '3. DMA Read A & B (MEM Bypass)',
    description: 'The Wrapper acts as a DMA master. It bypasses EX/MEM and drives accel_mem_addr to the Data Memory, reading 16 words of A and 16 words of B into its local buffers.',
    activePaths: ['accel_stall_fb', 'accel_stall_ifid', 'accel_stall_idex', 'accel_stall_hazard', 'accel_dma_addr', 'dmem_to_accel_rdata'],
    wrapperState: 'S_LOAD_A / S_LOAD_B'
  },
  {
    id: 'compute',
    title: '4. Q5.10 Systolic Compute (EX)',
    description: 'The Wrapper enters S_KICK. The Issue Logic streams data into the 4x4 Systolic Array. 16 PE cells concurrently perform Q5.10 MACs over 10 compute cycles.',
    activePaths: ['accel_stall_fb', 'accel_stall_ifid', 'accel_stall_idex', 'accel_stall_hazard'],
    wrapperState: 'S_KICK -> S_WAIT_ACC'
  },
  {
    id: 'dma_write',
    title: '5. DMA Writeback C (MEM Bypass)',
    description: 'Array asserts done. The Wrapper enters S_STORE_C, sign-extending the 16-bit results and driving accel_mem_wdata to store matrix C into Data Memory.',
    activePaths: ['accel_stall_fb', 'accel_stall_ifid', 'accel_stall_idex', 'accel_stall_hazard', 'accel_dma_addr', 'accel_dma_wdata'],
    wrapperState: 'S_STORE_C'
  },
  {
    id: 'commit',
    title: '6. PCPI Commit & WB (WB)',
    description: 'Wrapper completes memory writes, drops pcpi_wait, and asserts pcpi_ready. It passes c00 via pcpi_rd into the MEM_WB register, which writes it to rd.',
    activePaths: ['accel_pcpi_rd', 'accel_pcpi_ready', 'memwb_to_mux_data', 'mux_to_regfile'],
    wrapperState: 'S_RESP -> S_IDLE'
  }
];

// --- Wire Definitions with Labels ---
const ALL_WIRES = [
  // Standard Datapath
  { id: 'pc_to_imem', d: 'M 70 290 L 140 290', type: 'data', label: 'PC', labelPos: [105, 285] },
  { id: 'pc_to_adder', d: 'M 80 290 L 80 150 L 100 150', type: 'data' },
  { id: 'adder_to_mux', d: 'M 140 150 L 220 150 L 220 50 L 30 50 L 30 270 L 40 270', type: 'data' },
  { id: 'imem_to_ifid', d: 'M 220 290 L 260 290', type: 'data', label: 'Instruction', labelPos: [240, 285] },

  { id: 'ifid_to_reg_rs1', d: 'M 280 260 L 330 260', type: 'data', label: 'rs1 idx', labelPos: [305, 255] },
  { id: 'ifid_to_reg_rs2', d: 'M 280 320 L 330 320', type: 'data', label: 'rs2 idx', labelPos: [305, 315] },
  { id: 'ifid_to_imm', d: 'M 280 405 L 330 405', type: 'data' },
  { id: 'ifid_to_ctrl', d: 'M 280 120 L 325 120', type: 'ctrl' }, 

  { id: 'reg_to_idex_rs1', d: 'M 420 260 L 480 260', type: 'data', label: 'rs1 data', labelPos: [450, 255] },
  { id: 'reg_to_idex_rs2', d: 'M 420 320 L 480 320', type: 'data', label: 'rs2 data', labelPos: [450, 315] },
  { id: 'imm_to_idex', d: 'M 420 405 L 480 405', type: 'data', label: 'imm', labelPos: [450, 400] },
  { id: 'ctrl_to_idex', d: 'M 415 120 L 480 120', type: 'ctrl', label: 'ctrl', labelPos: [450, 115] },

  { id: 'idex_to_muxA', d: 'M 500 225 L 540 225', type: 'data' },
  { id: 'idex_to_muxB', d: 'M 500 305 L 540 305', type: 'data' },
  { id: 'idex_to_muxB_imm', d: 'M 500 405 L 520 405 L 520 325 L 540 325', type: 'data' },
  { id: 'idex_to_aluctrl', d: 'M 500 380 L 590 380', type: 'ctrl' },

  { id: 'muxA_to_alu', d: 'M 565 225 L 600 240', type: 'data' },
  { id: 'muxB_to_alu', d: 'M 565 305 L 600 280', type: 'data' },
  { id: 'aluctrl_to_alu', d: 'M 630 360 L 630 310', type: 'ctrl' },

  { id: 'alu_to_exmem', d: 'M 660 260 L 840 260', type: 'data', label: 'ALU Result', labelPos: [750, 255] },
  { id: 'idex_to_exmem_rs2', d: 'M 500 340 L 580 340 L 580 440 L 820 440 L 820 340 L 840 340', type: 'data' },

  { id: 'exmem_to_dmem_addr', d: 'M 860 260 L 910 260', type: 'data', label: 'mem_addr', labelPos: [885, 255] },
  { id: 'exmem_to_dmem_data', d: 'M 860 330 L 910 330', type: 'data', label: 'mem_wdata', labelPos: [885, 325] },
  { id: 'exmem_to_memwb_alu', d: 'M 860 240 L 1040 240 L 1040 260 L 1060 260', type: 'data' },
  { id: 'dmem_to_memwb', d: 'M 1000 290 L 1060 290', type: 'data', label: 'mem_rdata', labelPos: [1030, 285] },

  { id: 'memwb_to_mux_data', d: 'M 1080 290 L 1120 290', type: 'data' },
  { id: 'memwb_to_mux_alu', d: 'M 1080 260 L 1100 260 L 1100 270 L 1120 270', type: 'data' },
  { id: 'mux_to_regfile', d: 'M 1145 280 L 1180 280 L 1180 680 L 300 680 L 300 330 L 330 330', type: 'data', label: 'Writeback Data', labelPos: [740, 675] },

  // --- PCPI Wrapper & Custom Accel Wires ---
  { id: 'idex_to_accel_valid', d: 'M 500 110 L 515 110 L 515 480 L 530 480', type: 'ctrl_active', label: 'pcpi_valid', labelPos: [475, 475] },
  { id: 'idex_to_accel_rs1', d: 'M 500 250 L 510 250 L 510 520 L 530 520', type: 'data_active', label: 'pcpi_rs1', labelPos: [480, 515] },
  { id: 'idex_to_accel_rs2', d: 'M 500 310 L 520 310 L 520 540 L 530 540', type: 'data_active', label: 'pcpi_rs2', labelPos: [480, 535] },

  { id: 'accel_stall_fb', d: 'M 530 610 L 55 610 L 55 260', type: 'ctrl_active', label: 'pcpi_wait (STALL)', labelPos: [130, 605] },
  { id: 'accel_stall_ifid', d: 'M 55 610 L 55 80 L 270 80 L 270 100', type: 'ctrl_active' },
  { id: 'accel_stall_idex', d: 'M 270 80 L 490 80 L 490 100', type: 'ctrl_active' },
  { id: 'accel_stall_hazard', d: 'M 55 610 L 370 610 L 370 575', type: 'ctrl_active' },

  { id: 'accel_dma_addr', d: 'M 810 520 L 890 520 L 890 250 L 910 250', type: 'data_active', label: 'accel_mem_addr', labelPos: [850, 510] },
  { id: 'accel_dma_wdata', d: 'M 810 540 L 880 540 L 880 320 L 910 320', type: 'data_active', label: 'accel_mem_wdata', labelPos: [850, 535] },
  { id: 'dmem_to_accel_rdata', d: 'M 1000 290 L 1020 290 L 1020 570 L 810 570', type: 'data_active', label: 'accel_mem_rdata', labelPos: [915, 560] },

  { id: 'accel_pcpi_rd', d: 'M 810 600 L 1090 600 L 1090 300 L 1120 300', type: 'data_active', label: 'pcpi_rd (c00)', labelPos: [950, 595] },
  { id: 'accel_pcpi_ready', d: 'M 810 620 L 1150 620 L 1150 80 L 1070 80 L 1070 100', type: 'ctrl_active', label: 'pcpi_ready/wr', labelPos: [950, 615] },
];

// --- SVG Rendering Components (Classic 5-Stage Styling) ---
const BlockBlue = ({ x, y, w, h, title, subtitle }) => (
  <g transform={`translate(${x}, ${y})`}>
    <rect width={w} height={h} fill="#dae8fc" stroke="#6c8ebf" strokeWidth="2" rx="2" />
    <text x={w/2} y={subtitle ? h/2 - 6 : h/2 + 4} textAnchor="middle" className="text-[11px] font-bold fill-slate-800 font-sans">{title}</text>
    {subtitle && <text x={w/2} y={h/2 + 8} textAnchor="middle" className="text-[10px] fill-slate-700 font-sans">{subtitle}</text>}
  </g>
);

const PipeReg = ({ x, y, w, h, label }) => (
  <g transform={`translate(${x}, ${y})`}>
    <rect width={w} height={h} fill="#fff2cc" stroke="#d6b656" strokeWidth="2" />
    <text x={w/2} y="-8" textAnchor="middle" className="text-[11px] font-bold fill-slate-800 font-sans">{label}</text>
  </g>
);

const Mux = ({ x, y, w, h, label }) => (
  <g transform={`translate(${x}, ${y})`}>
    <polygon points={`0,0 ${w},${h*0.2} ${w},${h*0.8} 0,${h}`} fill="#e1d5e7" stroke="#9673a6" strokeWidth="2" />
    {label && <text x={w/2} y="-5" textAnchor="middle" className="text-[9px] fill-slate-600 font-sans">{label}</text>}
  </g>
);

const EllipseCtrl = ({ cx, cy, rx, ry, title }) => (
  <g>
    <ellipse cx={cx} cy={cy} rx={rx} ry={ry} fill="#dae8fc" stroke="#6c8ebf" strokeWidth="2" />
    <text x={cx} y={cy+3} textAnchor="middle" className="text-[10px] font-bold fill-slate-800 font-sans">{title}</text>
  </g>
);

const ALU = ({ x, y, w, h }) => (
  <g transform={`translate(${x}, ${y})`}>
    <polygon points={`0,0 ${w},${h/3} ${w},${h*2/3} 0,${h} 0,${h*0.65} ${w*0.25},${h/2} 0,${h*0.35}`} fill="#dae8fc" stroke="#6c8ebf" strokeWidth="2" />
    <text x={w/2+5} y={h/2+4} textAnchor="middle" className="text-[12px] font-bold fill-slate-800 font-sans">ALU</text>
  </g>
);

const CustomCoprocessor = ({ x, y, w, h, fsmState, activeInternal }) => (
  <g transform={`translate(${x}, ${y})`}>
    {/* Outline and Header */}
    <rect x="0" y="0" width={w} height={h} fill="#f8fafc" stroke="#64748b" strokeWidth="2" strokeDasharray="6" rx="6" />
    <rect x="0" y="0" width={w} height={30} fill="#e2e8f0" stroke="#64748b" strokeWidth="2" className="stroke-b-0" rx="6" />
    <text x={w/2} y="18" textAnchor="middle" className="text-sm font-bold fill-slate-800 font-sans">pcpi_tinyml_accel</text>
    
    {/* PCPI FSM */}
    <rect x="10" y="45" width="80" height="90" fill="#f1f5f9" stroke="#cbd5e1" strokeWidth="1" rx="4" />
    <text x="50" y="65" textAnchor="middle" className="text-[10px] font-bold fill-slate-700">Wrapper FSM</text>
    <text x="50" y="100" textAnchor="middle" className="text-[11px] font-mono font-bold fill-blue-600">{fsmState}</text>

    {/* 4x4 Systolic Array */}
    <rect x="110" y="40" width="160" height="100" fill="#fff1f2" stroke="#fda4af" strokeWidth="2" rx="4" />
    <text x="190" y="55" textAnchor="middle" className="text-[10px] font-bold fill-red-600">matrix_accel_4x4_q5_10</text>
    {[0,1,2,3].map(row => 
      [0,1,2,3].map(col => (
        <rect key={`${row}-${col}`} x={120 + col*34} y={65 + row*17} width="28" height="13" rx="2"
              className={`${activeInternal ? 'fill-red-200 stroke-red-400' : 'fill-white stroke-red-200'} stroke-1 transition-colors duration-200`} />
      ))
    )}
  </g>
);

const Wire = ({ d, active, type, label, labelPos }) => {
  let stroke = "#94a3b8";
  let strokeWidth = "2";
  let dash = "";
  let marker = "url(#arrow-slate)";

  if (type === 'ctrl') { stroke = "#60a5fa"; marker = "url(#arrow-blue)"; }

  if (active) {
    strokeWidth = "3";
    dash = "animate-dash stroke-dasharray-5";
    if (type.includes('data')) { stroke = "#ef4444"; marker = "url(#arrow-red)"; } 
    else { stroke = "#06b6d4"; marker = "url(#arrow-cyan)"; }
  } else if (type.includes('active')) {
    // Hide active-only wires when not in use to keep pipeline diagram clean
    return null;
  }

  return (
    <g>
      <path d={d} fill="none" stroke={stroke} strokeWidth={strokeWidth} className={`${dash} transition-all duration-300`} strokeLinejoin="round" markerEnd={marker} />
      {label && labelPos && (
        <text 
          x={labelPos[0]} 
          y={labelPos[1]} 
          textAnchor="middle"
          className={`text-[10px] font-mono font-bold transition-colors duration-300 ${active ? (type.includes('data') ? 'fill-red-600' : 'fill-cyan-700') : 'fill-slate-500'}`}
        >
          {label}
        </text>
      )}
    </g>
  );
};

// --- Main App Component ---
export default function App() {
  const [stageIdx, setStageIdx] = useState(0);
  const [isPlaying, setIsPlaying] = useState(false);

  useEffect(() => {
    if (!document.getElementById('tailwind-cdn')) {
      const script = document.createElement('script');
      script.id = 'tailwind-cdn';
      script.src = 'https://cdn.tailwindcss.com';
      document.head.appendChild(script);
    }
  }, []);

  const currentStage = STAGES[stageIdx];
  const isActive = (pathId) => currentStage.activePaths.includes(pathId);

  useEffect(() => {
    let timer;
    if (isPlaying) {
      timer = setTimeout(() => {
        setStageIdx((prev) => (prev + 1) % STAGES.length);
      }, 3500); // Slower pacing to read explanations
    }
    return () => clearTimeout(timer);
  }, [isPlaying, stageIdx]);

  return (
    <div className="flex h-screen w-full bg-slate-50 font-sans overflow-hidden">
      
      <style>{`
        .animate-dash {
          stroke-dasharray: 8;
          animation: dash 0.6s linear infinite;
        }
        @keyframes dash {
          to { stroke-dashoffset: -16; }
        }
      `}</style>

      {/* Main Diagram Area */}
      <div className="flex-1 flex flex-col h-full overflow-hidden p-4 relative">
        <div className="mb-2">
          <h1 className="text-2xl font-bold text-slate-800">Classic 5-Stage RV32IM Pipeline + TinyML Accel</h1>
          <p className="text-slate-600 text-sm">Validating drawio architecture mapping onto the 5-stage conceptual datapath</p>
        </div>

        <div className="relative bg-white border border-slate-200 shadow-sm rounded-lg flex-1 overflow-auto mt-2">
          <div className="min-w-[1250px] min-h-[750px] w-full h-full">
            <svg viewBox="0 0 1250 720" className="w-full h-full">
              <defs>
                <marker id="arrow-slate" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M 0 0 L 10 5 L 0 10 Z" fill="#94a3b8" /></marker>
              <marker id="arrow-red" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M 0 0 L 10 5 L 0 10 Z" fill="#ef4444" /></marker>
              <marker id="arrow-cyan" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="6" markerHeight="6" orient="auto"><path d="M 0 0 L 10 5 L 0 10 Z" fill="#06b6d4" /></marker>
            </defs>

            {/* --- Draw Standard 5-Stage Blocks First --- */}
            {/* Fetch Stage */}
            <BlockBlue x={40} y={260} w={30} h={60} title="PC" />
            <BlockBlue x={100} y={130} w={40} h={40} title="+4" />
            <BlockBlue x={140} y={230} w={80} h={120} title="Instruction" subtitle="memory" />
            <Mux x={20} y={40} w={20} h={40} label="" />

            <PipeReg x={260} y={100} w={20} h={560} label="IF_ID" />

            {/* Decode Stage */}
            <EllipseCtrl cx={370} cy={120} rx={45} ry={30} title="Control Unit" />
            <BlockBlue x={330} y={170} w={60} h={40} title="Branch" subtitle="Unit" />
            <BlockBlue x={330} y={230} w={90} h={120} title="Register" subtitle="File" />
            <BlockBlue x={330} y={380} w={90} h={50} title="Immediate" subtitle="Generation" />
            <EllipseCtrl cx={370} cy={550} rx={60} ry={25} title="Hazard Detection" />

            <PipeReg x={480} y={100} w={20} h={560} label="ID_EX" />

            {/* Execute Stage */}
            <Mux x={540} y={200} w={25} h={50} label="OpA" />
            <Mux x={540} y={280} w={25} h={50} label="OpB" />
            <ALU x={600} y={210} w={60} h={100} />
            <EllipseCtrl cx={630} cy={380} rx={40} ry={30} title="ALU Control" />

            {/* Custom Accelerator Coprocessor (In EX space) */}
            <CustomCoprocessor 
              x={530} y={470} w={280} h={160} 
              fsmState={currentStage.wrapperState} 
              activeInternal={currentStage.id === 'compute'} 
            />

            <PipeReg x={840} y={100} w={20} h={560} label="EX_MEM" />

            {/* Memory Stage */}
            <BlockBlue x={910} y={230} w={90} h={120} title="Data" subtitle="memory" />

            <PipeReg x={1060} y={100} w={20} h={560} label="MEM_WB" />

            {/* Write-Back Stage */}
            <Mux x={1120} y={250} w={25} h={60} label="" />


            {/* --- Draw All Routed Wires --- */}
            {ALL_WIRES.map(wire => (
              <Wire 
                key={wire.id} 
                d={wire.d} 
                type={wire.type} 
                active={isActive(wire.id)} 
                label={wire.label}
                labelPos={wire.labelPos}
              />
            ))}

            </svg>
          </div>
        </div>
      </div>

      {/* Side Control Panel */}
      <div className="w-[380px] bg-white border-l border-slate-200 p-6 flex flex-col h-full overflow-y-auto shadow-xl z-10 shrink-0">
        <h2 className="text-xl font-bold text-slate-800 mb-6 border-b pb-2">Execution Flow</h2>

        <div className="flex gap-2 mb-6">
          <button 
            onClick={() => setStageIdx((prev) => (prev - 1 + STAGES.length) % STAGES.length)}
            className="flex-1 bg-slate-100 hover:bg-slate-200 text-slate-800 font-bold py-2 px-4 rounded transition-colors"
          >
            Prev
          </button>
          <button 
            onClick={() => setIsPlaying(!isPlaying)}
            className={`flex-1 text-white font-bold py-2 px-4 rounded transition-colors ${isPlaying ? 'bg-amber-500 hover:bg-amber-600' : 'bg-blue-600 hover:bg-blue-700'}`}
          >
            {isPlaying ? 'Pause' : 'Auto Play'}
          </button>
          <button 
            onClick={() => setStageIdx((prev) => (prev + 1) % STAGES.length)}
            className="flex-1 bg-slate-100 hover:bg-slate-200 text-slate-800 font-bold py-2 px-4 rounded transition-colors"
          >
            Next
          </button>
        </div>

        <div className="space-y-4 mb-8 relative">
          {STAGES.map((s, idx) => (
            <div 
              key={s.id} 
              className={`p-3 rounded-lg border-2 cursor-pointer transition-all ${idx === stageIdx ? 'border-blue-500 bg-blue-50 shadow-md' : 'border-transparent hover:bg-slate-50'}`}
              onClick={() => setStageIdx(idx)}
            >
              <h3 className={`font-bold text-sm ${idx === stageIdx ? 'text-blue-700' : 'text-slate-600'}`}>
                {s.title}
              </h3>
              {idx === stageIdx && (
                <p className="text-sm text-slate-700 mt-2 leading-relaxed">
                  {s.description}
                </p>
              )}
            </div>
          ))}
        </div>

        <div className="bg-slate-800 text-slate-200 rounded-lg p-4 mt-auto text-[11px] font-mono shadow-inner">
          <h4 className="text-white font-bold mb-2 font-sans border-b border-slate-600 pb-1">Spec Validation Checklist</h4>
          <div className="space-y-2">
            <div><span className="text-green-400">✔</span> Base architecture: RV32IM</div>
            <div><span className="text-green-400">✔</span> Coprocessor Intf: PCPI</div>
            <div><span className="text-green-400">✔</span> DMA Flow: Shared RAM Access</div>
            <div><span className="text-green-400">✔</span> Data Path: Q5.10 Matrix Multiply</div>
            <div><span className="text-green-400">✔</span> Pipeline Impact: Hazard stall via <code>pcpi_wait</code></div>
          </div>
        </div>
      </div>
    </div>
  );
}