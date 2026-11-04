using System;

namespace Ryujinx.Graphics.Shader.Translation
{
    [Flags]
    public enum TranslationFlags
    {
        None = 0,

        VertexA = 1 << 0,
        Compute = 1 << 1,
        DebugMode = 1 << 2,
        // Offline Metal: image atomics run natively on the texture (MSL 3.1), guarded for IGN bounds.
        MetalImageAtomics = 1 << 3,
        // nxnative: a Switch 2 task / mesh program, translated as compute (with Compute) and emitted as a SPIR-V TaskEXT / MeshEXT entry point (StructuredIr/MeshShaderInfo.cs)
        TaskShader = 1 << 4,
        MeshShader = 1 << 5,
    }
}
