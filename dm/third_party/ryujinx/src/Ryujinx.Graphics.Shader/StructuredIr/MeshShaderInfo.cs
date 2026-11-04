using System;
using Ryujinx.Graphics.Shader.Translation;

namespace Ryujinx.Graphics.Shader.StructuredIr
{
    // nxnative: a Switch 2 task / mesh program. Its stage memory reaches the translator as shared memory in windows (nx2_lower: offset = window << 20 | address):
    // 1 the workgroup index (read at 0), 2 / 3 the task memory (mesh reads, task writes; +4 = mesh groups to launch, +0x10 … payload), 4 the per-vertex planes in chunks of
    // 32 vertices (vertex v, plane p at (v / 32) x planes x 0x80 + p x 0x80 + (v % 32) x 4 bytes: bdd0256e66c69a11 computes (v >> 5) x 0x300 + (v & 31) x 4 for its 6 planes), then the
    // per-primitive values in chunks of 32 primitives (primitive p, value n at chunks(max vertices) x planes x 0x80 + (p / 32) x values x 0x80 + n x 0x80 + (p % 32) x 4; which outputs they are:
    // nx2_split.py mesh_prim, after a -1 in the layout), 5 / 6 the primitive area (byte 3 = primitive count, 4 + 3 t … = triangle t's indices). Each becomes a memory of its own:
    // the task memory in TaskPayloadWorkgroupEXT storage, the others in workgroup memory; the SPIR-V entry point copies them into the mesh outputs (SpirvGenerator)
    class MeshShaderInfo
    {
        public const string PayloadName = "task_payload";

        public bool IsTask { get; }
        public bool IsMesh { get; }
        public int MaxVertices { get; }
        public int MaxPrimitives { get; }
        public int PayloadWords { get; }
        public int[] Planes { get; }
        public int[] PrimitivePlanes { get; }

        // Words of the plane and primitive memories: powers of two, every address masked into them (a stray store stays inside)
        public int PlaneWords { get; }
        public int PrimitiveWords { get; }

        public int PayloadMemoryId { get; private set; } = -1;
        public int PlaneMemoryId { get; private set; } = -1;
        public int PrimitiveMemoryId { get; private set; } = -1;

        public MeshShaderInfo(bool isTask, int[] layout)
        {
            IsTask = isTask;
            IsMesh = !isTask;
            MaxVertices = layout != null && layout.Length > 0 ? layout[0] : 32;
            MaxPrimitives = layout != null && layout.Length > 1 ? layout[1] : 32;
            PayloadWords = layout != null && layout.Length > 2 ? (layout[2] + 3) / 4 : 0x400;
            if (PayloadWords < 4)
            {
                PayloadWords = 4;
            }

            int end = layout != null && layout.Length > 3 ? layout.Length : 3;
            int split = layout != null ? Array.IndexOf(layout, -1, 3) : -1;
            if (split < 0)
            {
                split = end;
            }

            Planes = layout != null ? layout[3..split] : Array.Empty<int>();
            PrimitivePlanes = layout != null && split < end ? layout[(split + 1)..end] : Array.Empty<int>();
            int planes = Planes.Length;

            // Room for the vertex chunks and, after them, the per-primitive values (10bfb4e32ae8c05b stores one at + 0x300; b9edd9c570bd32dd 13, 22 KB in all). Metal gives a
            // mesh function 32 KB of threadgroup memory
            // Exact, not a power of two: the addresses are clamped into it (Window), not masked. b9edd9c570bd32dd missed Metal's limit by 8 bytes with the power of two (32,776)
            PlaneWords = Chunks(MaxVertices) * planes * 32 + Chunks(MaxPrimitives) * PrimitivePlanes.Length * 32;
            PrimitiveWords = PowerOfTwo((4 + 3 * MaxPrimitives + 3) / 4 + 64);
        }

        public static int Chunks(int n)
        {
            return (n + 31) / 32;
        }

        // The word of vertex v's plane p (VertexChunkWords = planes x 32)
        public int VertexChunkWords => Planes.Length * 32;

        // The first word of the per-primitive values and the words of one 32-primitive chunk of them
        public int PrimitiveBaseWord => Chunks(MaxVertices) * VertexChunkWords;
        public int PrimitiveChunkWords => PrimitivePlanes.Length * 32;

        private static int PowerOfTwo(int n)
        {
            int p = 1;
            while (p < n)
            {
                p <<= 1;
            }

            return p;
        }

        public void Declare(ShaderProperties properties)
        {
            if (PayloadMemoryId >= 0)
            {
                return;
            }

            PayloadMemoryId = properties.AddSharedMemory(new MemoryDefinition(PayloadName, AggregateType.Array | AggregateType.U32, PayloadWords));

            if (IsMesh)
            {
                // One word: its stores go straight into the mesh outputs (CodeGenContext.MeshPlaneStore); PlaneWords still bounds their addresses (Window)
                PlaneMemoryId = properties.AddSharedMemory(new MemoryDefinition("mesh_vertex_planes", AggregateType.Array | AggregateType.U32, 1));
                PrimitiveMemoryId = properties.AddSharedMemory(new MemoryDefinition("mesh_primitives", AggregateType.Array | AggregateType.U32, PrimitiveWords));
            }
        }

        // The memory of a window and how its addresses stay in it: a positive byteMask is ANDed in, a negative one is the largest byte address, clamped to (id -1: no memory,
        // the window is read some other way)
        public (int id, int byteMask) Window(int window)
        {
            return window switch
            {
                2 or 3 => (PayloadMemoryId, PayloadWords * 4 - 1),
                4 => (PlaneMemoryId, -(PlaneWords * 4 - 4)),
                5 or 6 => (PrimitiveMemoryId, PrimitiveWords * 4 - 1),
                _ => (-1, 0),
            };
        }
    }
}
