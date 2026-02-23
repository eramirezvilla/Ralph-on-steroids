import { useCallback, useState, useRef } from 'react';
import type { Node, Edge, NodeChange, EdgeChange, Connection } from '@xyflow/react';
import {
  ReactFlow,
  useNodesState,
  useEdgesState,
  Controls,
  Background,
  BackgroundVariant,
  MarkerType,
  applyNodeChanges,
  applyEdgeChanges,
  addEdge,
  Handle,
  Position,
  reconnectEdge,
} from '@xyflow/react';
import '@xyflow/react/dist/style.css';
import './App.css';

const nodeWidth = 240;
const nodeHeight = 70;

type Phase = 'setup' | 'dual' | 'merge' | 'loop' | 'review' | 'decision' | 'done';

const phaseColors: Record<Phase, { bg: string; border: string }> = {
  setup: { bg: '#f0f7ff', border: '#4a90d9' },
  dual: { bg: '#f0f0ff', border: '#6b5ce7' },
  merge: { bg: '#fff0f5', border: '#d94a8a' },
  loop: { bg: '#f5f5f5', border: '#666666' },
  review: { bg: '#fff3e6', border: '#e67e22' },
  decision: { bg: '#fff8e6', border: '#c9a227' },
  done: { bg: '#f0fff4', border: '#38a169' },
};

const allSteps: { id: string; label: string; description: string; phase: Phase }[] = [
  // Setup
  { id: '1', label: 'Feature description', description: 'User describes what to build', phase: 'setup' },

  // Dual PRD creation
  { id: '2a', label: 'PRD Author A', description: 'Technical depth focus', phase: 'dual' },
  { id: '2b', label: 'PRD Author B', description: 'User experience focus', phase: 'dual' },
  { id: '3', label: 'PRD Merger', description: 'Synthesizes best of both', phase: 'merge' },
  { id: '4', label: 'prd.json with phases', description: 'Phased user stories created', phase: 'setup' },

  // Phase planning (single balanced planner)
  { id: '5', label: 'Phase Planner', description: 'Balanced plan (skip if 1 story)', phase: 'merge' },

  // Execution loop
  { id: '7', label: 'AI picks a story', description: 'From current phase', phase: 'loop' },
  { id: '8', label: 'Implements it', description: 'Writes code, runs tests', phase: 'loop' },
  { id: '9', label: 'Commits changes', description: 'If tests pass', phase: 'loop' },
  { id: '10', label: 'Updates prd.json', description: 'Sets passes: true', phase: 'loop' },
  { id: '11', label: 'Logs to progress.txt', description: 'Saves learnings', phase: 'loop' },
  { id: '12', label: 'Phase stories done?', description: '', phase: 'decision' },

  // Phase review
  { id: '13', label: 'Phase Reviewer', description: 'Reviews completed work', phase: 'review' },
  { id: '14', label: 'Approved?', description: '', phase: 'decision' },

  // Targeted fix (on rejection)
  { id: '17', label: 'Targeted Fix', description: 'Only failed stories re-executed', phase: 'review' },

  // More phases
  { id: '15', label: 'More phases?', description: '', phase: 'decision' },

  // Done
  { id: '16', label: 'Done!', description: 'All phases complete', phase: 'done' },
];

const notes = [
  {
    id: 'note-1',
    appearsWithStep: 4,
    position: { x: 580, y: 20 },
    color: { bg: '#f5f0ff', border: '#8b5cf6' },
    content: `Two authors independently write
PRDs with different lenses, then
a merger combines the best of both.`,
  },
  {
    id: 'note-2',
    appearsWithStep: 6,
    position: { x: 580, y: 400 },
    color: { bg: '#e6f7ff', border: '#1890ff' },
    content: `Single balanced planner for 2+
stories. Single-story phases
skip planning entirely.`,
  },
  {
    id: 'note-3',
    appearsWithStep: 14,
    position: { x: 580, y: 920 },
    color: { bg: '#fff3e6', border: '#e67e22' },
    content: `Reviewer checks if work matches
the PRD. Rejection triggers targeted
fix of only the failed stories.`,
  },
];

function CustomNode({ data }: { data: { title: string; description: string; phase: Phase } }) {
  const colors = phaseColors[data.phase];
  return (
    <div
      className="custom-node"
      style={{
        backgroundColor: colors.bg,
        borderColor: colors.border,
      }}
    >
      <Handle type="target" position={Position.Top} id="top" />
      <Handle type="target" position={Position.Left} id="left" />
      <Handle type="source" position={Position.Right} id="right" />
      <Handle type="source" position={Position.Bottom} id="bottom" />
      <Handle type="target" position={Position.Right} id="right-target" style={{ right: 0 }} />
      <Handle type="target" position={Position.Bottom} id="bottom-target" style={{ bottom: 0 }} />
      <Handle type="source" position={Position.Top} id="top-source" />
      <Handle type="source" position={Position.Left} id="left-source" />
      <div className="node-content">
        <div className="node-title">{data.title}</div>
        {data.description && <div className="node-description">{data.description}</div>}
      </div>
    </div>
  );
}

function NoteNode({ data }: { data: { content: string; color: { bg: string; border: string } } }) {
  return (
    <div
      className="note-node"
      style={{
        backgroundColor: data.color.bg,
        borderColor: data.color.border,
      }}
    >
      <pre>{data.content}</pre>
    </div>
  );
}

const nodeTypes = { custom: CustomNode, note: NoteNode };

// Layout positions
const positions: { [key: string]: { x: number; y: number } } = {
  // Setup
  '1': { x: 180, y: 20 },

  // Dual PRD - fork
  '2a': { x: 40, y: 120 },
  '2b': { x: 320, y: 120 },

  // Merge
  '3': { x: 180, y: 230 },

  // prd.json
  '4': { x: 180, y: 330 },

  // Phase planning (single)
  '5': { x: 180, y: 430 },

  // Execution loop
  '7': { x: 40, y: 540 },
  '8': { x: 320, y: 540 },
  '9': { x: 320, y: 640 },
  '10': { x: 180, y: 740 },
  '11': { x: 40, y: 640 },
  '12': { x: 40, y: 840 },

  // Review
  '13': { x: 180, y: 940 },

  // Approved?
  '14': { x: 180, y: 1040 },

  // Targeted fix (rejection path)
  '17': { x: 440, y: 1040 },

  // More phases?
  '15': { x: 180, y: 1160 },

  // Done
  '16': { x: 180, y: 1280 },

  // Notes
  ...Object.fromEntries(notes.map((n) => [n.id, n.position])),
};

const edgeConnections: {
  source: string;
  target: string;
  sourceHandle?: string;
  targetHandle?: string;
  label?: string;
}[] = [
  // Setup → dual PRD fork
  { source: '1', target: '2a', sourceHandle: 'bottom', targetHandle: 'top' },
  { source: '1', target: '2b', sourceHandle: 'bottom', targetHandle: 'top' },

  // Dual PRD → merger
  { source: '2a', target: '3', sourceHandle: 'bottom', targetHandle: 'top' },
  { source: '2b', target: '3', sourceHandle: 'bottom', targetHandle: 'top' },

  // Merger → prd.json
  { source: '3', target: '4', sourceHandle: 'bottom', targetHandle: 'top' },

  // prd.json → Phase Planner (single)
  { source: '4', target: '5', sourceHandle: 'bottom', targetHandle: 'top' },

  // Phase Planner → execution
  { source: '5', target: '7', sourceHandle: 'bottom', targetHandle: 'top' },

  // Execution loop
  { source: '7', target: '8', sourceHandle: 'right', targetHandle: 'left' },
  { source: '8', target: '9', sourceHandle: 'bottom', targetHandle: 'top' },
  { source: '9', target: '10', sourceHandle: 'left-source', targetHandle: 'right-target' },
  { source: '10', target: '11', sourceHandle: 'left-source', targetHandle: 'right-target' },
  { source: '11', target: '12', sourceHandle: 'bottom', targetHandle: 'top' },

  // Phase stories done? → loop back or review
  { source: '12', target: '7', sourceHandle: 'top-source', targetHandle: 'bottom-target', label: 'No' },
  { source: '12', target: '13', sourceHandle: 'right', targetHandle: 'left', label: 'Yes' },

  // Review → approved?
  { source: '13', target: '14', sourceHandle: 'bottom', targetHandle: 'top' },

  // Approved? → targeted fix or more phases
  { source: '14', target: '17', sourceHandle: 'right', targetHandle: 'left', label: 'No' },
  { source: '14', target: '15', sourceHandle: 'bottom', targetHandle: 'top', label: 'Yes' },

  // Targeted fix → back to execution loop
  { source: '17', target: '7', sourceHandle: 'top-source', targetHandle: 'right-target' },

  // More phases? → next phase planning or done
  { source: '15', target: '5', sourceHandle: 'left-source', targetHandle: 'bottom-target', label: 'Yes' },
  { source: '15', target: '16', sourceHandle: 'bottom', targetHandle: 'top', label: 'No' },
];

function createNode(
  step: (typeof allSteps)[0],
  visible: boolean,
  position?: { x: number; y: number }
): Node {
  return {
    id: step.id,
    type: 'custom',
    position: position || positions[step.id],
    data: {
      title: step.label,
      description: step.description,
      phase: step.phase,
    },
    style: {
      width: nodeWidth,
      height: nodeHeight,
      opacity: visible ? 1 : 0,
      transition: 'opacity 0.5s ease-in-out',
      pointerEvents: visible ? 'auto' : 'none',
    },
  };
}

function createEdge(conn: (typeof edgeConnections)[0], visible: boolean): Edge {
  return {
    id: `e${conn.source}-${conn.target}`,
    source: conn.source,
    target: conn.target,
    sourceHandle: conn.sourceHandle,
    targetHandle: conn.targetHandle,
    label: visible ? conn.label : undefined,
    animated: visible,
    style: {
      stroke: '#222',
      strokeWidth: 2,
      opacity: visible ? 1 : 0,
      transition: 'opacity 0.5s ease-in-out',
    },
    labelStyle: {
      fill: '#222',
      fontWeight: 600,
      fontSize: 14,
    },
    labelShowBg: true,
    labelBgPadding: [8, 4] as [number, number],
    labelBgStyle: {
      fill: '#fff',
      stroke: '#222',
      strokeWidth: 1,
    },
    markerEnd: {
      type: MarkerType.ArrowClosed,
      color: '#222',
    },
  };
}

function createNoteNode(
  note: (typeof notes)[0],
  visible: boolean,
  position?: { x: number; y: number }
): Node {
  return {
    id: note.id,
    type: 'note',
    position: position || positions[note.id],
    data: { content: note.content, color: note.color },
    style: {
      opacity: visible ? 1 : 0,
      transition: 'opacity 0.5s ease-in-out',
      pointerEvents: visible ? 'auto' : 'none',
    },
    draggable: true,
    selectable: false,
    connectable: false,
  };
}

function App() {
  const [visibleCount, setVisibleCount] = useState(1);
  const nodePositions = useRef<{ [key: string]: { x: number; y: number } }>({ ...positions });

  const getNodes = (count: number) => {
    const stepNodes = allSteps.map((step, index) =>
      createNode(step, index < count, nodePositions.current[step.id])
    );
    const noteNodes = notes.map((note) => {
      const noteVisible = count >= note.appearsWithStep;
      return createNoteNode(note, noteVisible, nodePositions.current[note.id]);
    });
    return [...stepNodes, ...noteNodes];
  };

  const initialNodes = getNodes(1);
  const initialEdges = edgeConnections.map((conn) => createEdge(conn, false));

  const [nodes, setNodes] = useNodesState(initialNodes);
  const [edges, setEdges] = useEdgesState(initialEdges);

  const onNodesChange = useCallback(
    (changes: NodeChange[]) => {
      changes.forEach((change) => {
        if (change.type === 'position' && change.position) {
          nodePositions.current[change.id] = change.position;
        }
      });
      setNodes((nds) => applyNodeChanges(changes, nds));
    },
    [setNodes]
  );

  const onEdgesChange = useCallback(
    (changes: EdgeChange[]) => {
      setEdges((eds) => applyEdgeChanges(changes, eds));
    },
    [setEdges]
  );

  const onConnect = useCallback(
    (connection: Connection) => {
      setEdges((eds) =>
        addEdge(
          {
            ...connection,
            animated: true,
            style: { stroke: '#222', strokeWidth: 2 },
            markerEnd: { type: MarkerType.ArrowClosed, color: '#222' },
          },
          eds
        )
      );
    },
    [setEdges]
  );

  const onReconnect = useCallback(
    (oldEdge: Edge, newConnection: Connection) => {
      setEdges((eds) => reconnectEdge(oldEdge, newConnection, eds));
    },
    [setEdges]
  );

  const getEdgeVisibility = (conn: (typeof edgeConnections)[0], visibleStepCount: number) => {
    const sourceIndex = allSteps.findIndex((s) => s.id === conn.source);
    const targetIndex = allSteps.findIndex((s) => s.id === conn.target);
    return sourceIndex < visibleStepCount && targetIndex < visibleStepCount;
  };

  const handleNext = useCallback(() => {
    if (visibleCount < allSteps.length) {
      const newCount = visibleCount + 1;
      setVisibleCount(newCount);

      setNodes(getNodes(newCount));
      setEdges(edgeConnections.map((conn) => createEdge(conn, getEdgeVisibility(conn, newCount))));
    }
  }, [visibleCount, setNodes, setEdges]);

  const handlePrev = useCallback(() => {
    if (visibleCount > 1) {
      const newCount = visibleCount - 1;
      setVisibleCount(newCount);

      setNodes(getNodes(newCount));
      setEdges(edgeConnections.map((conn) => createEdge(conn, getEdgeVisibility(conn, newCount))));
    }
  }, [visibleCount, setNodes, setEdges]);

  const handleReset = useCallback(() => {
    setVisibleCount(1);
    nodePositions.current = { ...positions };
    setNodes(getNodes(1));
    setEdges(edgeConnections.map((conn) => createEdge(conn, false)));
  }, [setNodes, setEdges]);

  return (
    <div className="app-container">
      <div className="header">
        <h1>How Ralph Works</h1>
        <p>Multi-phase autonomous AI agent loop with review gates and targeted fixes</p>
      </div>
      <div className="flow-container">
        <ReactFlow
          nodes={nodes}
          edges={edges}
          nodeTypes={nodeTypes}
          onNodesChange={onNodesChange}
          onEdgesChange={onEdgesChange}
          onConnect={onConnect}
          onReconnect={onReconnect}
          fitView
          fitViewOptions={{ padding: 0.2 }}
          nodesDraggable={true}
          nodesConnectable={true}
          edgesReconnectable={true}
          elementsSelectable={true}
          deleteKeyCode={['Backspace', 'Delete']}
          panOnDrag={true}
          panOnScroll={true}
          zoomOnScroll={true}
          zoomOnPinch={true}
          zoomOnDoubleClick={true}
          selectNodesOnDrag={false}
        >
          <Background variant={BackgroundVariant.Dots} gap={20} size={1} color="#ddd" />
          <Controls showInteractive={false} />
        </ReactFlow>
      </div>
      <div className="controls">
        <button onClick={handlePrev} disabled={visibleCount <= 1}>
          Previous
        </button>
        <span className="step-counter">
          Step {visibleCount} of {allSteps.length}
        </span>
        <button onClick={handleNext} disabled={visibleCount >= allSteps.length}>
          Next
        </button>
        <button onClick={handleReset} className="reset-btn">
          Reset
        </button>
      </div>
      <div className="instructions">Click Next to reveal each step</div>
    </div>
  );
}

export default App;
