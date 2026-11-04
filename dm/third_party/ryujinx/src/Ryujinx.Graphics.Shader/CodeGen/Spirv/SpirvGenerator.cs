using Ryujinx.Common;
using Ryujinx.Graphics.Shader.IntermediateRepresentation;
using Ryujinx.Graphics.Shader.StructuredIr;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.Threading;
using static Spv.Specification;

namespace Ryujinx.Graphics.Shader.CodeGen.Spirv
{
    using SpvInstruction = Spv.Generator.Instruction;
    using SpvInstructionPool = Spv.Generator.GeneratorPool<Spv.Generator.Instruction>;
    using SpvLiteralInteger = Spv.Generator.LiteralInteger;
    using SpvLiteralIntegerPool = Spv.Generator.GeneratorPool<Spv.Generator.LiteralInteger>;

    static class SpirvGenerator
    {
        // Resource pools for Spirv generation. Note: Increase count when more threads are being used.
        private const int GeneratorPoolCount = 1;
        private static readonly ObjectPool<SpvInstructionPool> _instructionPool;
        private static readonly ObjectPool<SpvLiteralIntegerPool> _integerPool;
        private static readonly Lock _poolLock = new();

        static SpirvGenerator()
        {
            _instructionPool = new(() => new SpvInstructionPool(), GeneratorPoolCount);
            _integerPool = new(() => new SpvLiteralIntegerPool(), GeneratorPoolCount);
        }

        private const HelperFunctionsMask NeedsInvocationIdMask = HelperFunctionsMask.SwizzleAdd;

        public static byte[] Generate(StructuredProgramInfo info, CodeGenParameters parameters)
        {
            SpvInstructionPool instPool;
            SpvLiteralIntegerPool integerPool;

            lock (_poolLock)
            {
                instPool = _instructionPool.Allocate();
                integerPool = _integerPool.Allocate();
            }

            CodeGenContext context = new(info, parameters, instPool, integerPool);

            context.AddCapability(Capability.Shader);

            context.SetMemoryModel(AddressingModel.Logical, MemoryModel.GLSL450);

            context.AddCapability(Capability.GroupNonUniformBallot);
            context.AddCapability(Capability.GroupNonUniformShuffle);
            context.AddCapability(Capability.GroupNonUniformVote);
            context.AddCapability(Capability.ImageBuffer);
            context.AddCapability(Capability.ImageGatherExtended);
            context.AddCapability(Capability.ImageQuery);
            context.AddCapability(Capability.SampledBuffer);

            if (parameters.HostCapabilities.SupportsShaderFloat64)
            {
                context.AddCapability(Capability.Float64);
            }

            if (parameters.Definitions.TransformFeedbackEnabled && parameters.Definitions.LastInVertexPipeline)
            {
                context.AddCapability(Capability.TransformFeedback);
            }

            if (parameters.Definitions.Stage == ShaderStage.Fragment)
            {
                if (context.Info.IoDefinitions.Contains(new IoDefinition(StorageKind.Input, IoVariable.Layer)) ||
                    context.Info.IoDefinitions.Contains(new IoDefinition(StorageKind.Input, IoVariable.PrimitiveId)))
                {
                    context.AddCapability(Capability.Geometry);
                }

                if (context.HostCapabilities.SupportsFragmentShaderInterlock)
                {
                    context.AddCapability(Capability.FragmentShaderPixelInterlockEXT);
                    context.AddExtension("SPV_EXT_fragment_shader_interlock");
                }
            }
            else if (parameters.Definitions.Stage == ShaderStage.Geometry)
            {
                context.AddCapability(Capability.Geometry);

                if (parameters.Definitions.GpPassthrough && context.HostCapabilities.SupportsGeometryShaderPassthrough)
                {
                    context.AddExtension("SPV_NV_geometry_shader_passthrough");
                    context.AddCapability(Capability.GeometryShaderPassthroughNV);
                }
            }
            else if (parameters.Definitions.Stage is ShaderStage.TessellationControl or
                     ShaderStage.TessellationEvaluation)
            {
                context.AddCapability(Capability.Tessellation);
            }
            else if (parameters.Definitions.Stage == ShaderStage.Vertex)
            {
                context.AddCapability(Capability.DrawParameters);
            }

            if (context.Definitions.Stage != ShaderStage.Fragment &&
                context.Definitions.Stage != ShaderStage.Geometry &&
                context.Definitions.Stage != ShaderStage.Compute &&
                (context.Info.IoDefinitions.Contains(new IoDefinition(StorageKind.Output, IoVariable.Layer)) ||
                context.Info.IoDefinitions.Contains(new IoDefinition(StorageKind.Output, IoVariable.ViewportIndex))))
            {
                context.AddExtension("SPV_EXT_shader_viewport_index_layer");
                context.AddCapability(Capability.ShaderViewportIndexLayerEXT);
            }

            if (context.Info.IoDefinitions.Contains(new IoDefinition(StorageKind.Output, IoVariable.ViewportMask)))
            {
                context.AddExtension("SPV_NV_viewport_array2");
                context.AddCapability(Capability.ShaderViewportMaskNV);
            }

            if ((info.HelperFunctionsMask & NeedsInvocationIdMask) != 0)
            {
                info.IoDefinitions.Add(new IoDefinition(StorageKind.Input, IoVariable.SubgroupLaneId));
            }

            Declarations.DeclareAll(context, info);

            for (int funcIndex = 0; funcIndex < info.Functions.Count; funcIndex++)
            {
                StructuredFunction function = info.Functions[funcIndex];
                SpvInstruction retType = context.GetType(function.ReturnType);

                SpvInstruction[] funcArgs = new SpvInstruction[function.InArguments.Length + function.OutArguments.Length];

                for (int argIndex = 0; argIndex < funcArgs.Length; argIndex++)
                {
                    SpvInstruction argType = context.GetType(function.GetArgumentType(argIndex));
                    SpvInstruction argPointerType = context.TypePointer(StorageClass.Function, argType);
                    funcArgs[argIndex] = argPointerType;
                }

                SpvInstruction funcType = context.TypeFunction(retType, false, funcArgs);
                SpvInstruction spvFunc = context.Function(retType, FunctionControlMask.MaskNone, funcType);

                context.DeclareFunction(funcIndex, function, spvFunc);
            }

            for (int funcIndex = 0; funcIndex < info.Functions.Count; funcIndex++)
            {
                Generate(context, info, funcIndex);
            }

            if (context.Properties.Mesh != null)
            {
                GenerateMeshEntry(context, context.Properties.Mesh);
            }

            byte[] result = context.Generate();

            lock (_poolLock)
            {
                _instructionPool.Release(instPool);
                _integerPool.Release(integerPool);
            }

            return result;
        }

        // nxnative: the entry point of a Switch 2 task / mesh program (StructuredIr/MeshShaderInfo.cs). The translated program is function 0, run as a compute body: its
        // early returns stay legal. The wrapper calls it, waits for the workgroup, then hands the stage memory over the way SPV_EXT_mesh_shader wants it:
        //   task: the payload word 0 cleared (the base address a mesh workgroup reads first), EmitMeshTasksEXT(word 1 = mesh groups to launch, 1, 1, payload)
        //   mesh: SetMeshOutputsEXT(MaxVertices, primitive count = byte 3), then every vertex's planes into the outputs (position, generic attributes at their
        //         locations) and every triangle's three index bytes (4 + 3 t) into PrimitiveTriangleIndicesEXT, each workgroup thread taking every threads-th one
        private static void GenerateMeshEntry(CodeGenContext context, MeshShaderInfo mesh)
        {
            context.AddCapability(Capability.MeshShadingEXT);
            context.AddExtension("SPV_EXT_mesh_shader");

            SpvInstruction tVoid = context.TypeVoid(), tU32 = context.TypeU32(), tF32 = context.TypeFP32(), tBool = context.TypeBool();
            SpvInstruction tVec4 = context.TypeVector(tF32, 4), tUVec3 = context.TypeVector(tU32, 3);
            SpvInstruction U(uint v) => context.Constant(tU32, v);
            int threads = Math.Max(1, context.Definitions.ComputeLocalSizeX * context.Definitions.ComputeLocalSizeY * context.Definitions.ComputeLocalSizeZ);
            List<SpvInstruction> io = new(context.GetMainInterface());

            SpvInstruction lidVar = context.Variable(context.TypePointer(StorageClass.Input, tU32), StorageClass.Input);
            context.Decorate(lidVar, Decoration.BuiltIn, (SpvLiteralInteger)BuiltIn.LocalInvocationIndex);
            context.AddGlobalVariable(lidVar);
            io.Add(lidVar);

            SpvInstruction payload = context.SharedMemories[mesh.PayloadMemoryId];
            io.Add(payload);

            // Mesh outputs: the position (in a per-vertex block), one vec4 array per generic attribute the planes name, the triangles
            SpvInstruction posVar = null, idxVar = null;
            Dictionary<int, SpvInstruction> generics = new(), primGenerics = new();
            if (mesh.IsMesh)
            {
                SpvInstruction perVertex = context.TypeStruct(true, tVec4);
                context.Decorate(perVertex, Decoration.Block);
                context.MemberDecorate(perVertex, 0, Decoration.BuiltIn, (SpvLiteralInteger)BuiltIn.Position);
                posVar = context.Variable(context.TypePointer(StorageClass.Output, context.TypeArray(perVertex, U((uint)mesh.MaxVertices))), StorageClass.Output);
                context.AddGlobalVariable(posVar);
                io.Add(posVar);

                // Per-primitive outputs (the paired pixel shader's flat inputs, MeshShaderInfo.PrimitivePlanes): one vec4 array per generic location, one element per primitive
                foreach (int plane in mesh.PrimitivePlanes)
                {
                    int g = (plane - 4) >> 2;
                    if (plane < 4 || primGenerics.ContainsKey(g))
                    {
                        continue;
                    }

                    SpvInstruction v = context.Variable(context.TypePointer(StorageClass.Output, context.TypeArray(tVec4, U((uint)mesh.MaxPrimitives))), StorageClass.Output);
                    context.Decorate(v, Decoration.Location, (SpvLiteralInteger)g);
                    context.Decorate(v, Decoration.PerPrimitiveEXT);
                    context.AddGlobalVariable(v);
                    primGenerics[g] = v;
                    io.Add(v);
                }

                // Every other generic location 0-5 gets a per-vertex output (the highest a mesh-paired pixel shader reads is g5; 0-7 overflowed Metal's 32 KB mesh output limit on
                // b9edd9c570bd32dd): Metal refuses (or its compiler service dies on) a mesh pipeline whose fragment inputs the mesh does not provide. Unwritten ones hold (0, 0, 0, 1)
                // as dmsh_build.py vs_pad gives a vertex shader's (put there by dmsh_build.py ms_pad)
                for (int plane = 4; plane < 4 + 6 * 4; plane += 4)
                {
                    int g = (plane - 4) >> 2;
                    if (generics.ContainsKey(g) || primGenerics.ContainsKey(g))
                    {
                        continue;
                    }

                    SpvInstruction v = context.Variable(context.TypePointer(StorageClass.Output, context.TypeArray(tVec4, U((uint)mesh.MaxVertices))), StorageClass.Output);
                    context.Decorate(v, Decoration.Location, (SpvLiteralInteger)g);
                    context.AddGlobalVariable(v);
                    generics[g] = v;
                    io.Add(v);
                }

                idxVar = context.Variable(context.TypePointer(StorageClass.Output, context.TypeArray(tUVec3, U((uint)mesh.MaxPrimitives))), StorageClass.Output);
                context.Decorate(idxVar, Decoration.BuiltIn, (SpvLiteralInteger)BuiltIn.PrimitiveTriangleIndicesEXT);
                context.AddGlobalVariable(idxVar);
                io.Add(idxVar);
            }

            (_, SpvInstruction body) = context.GetFunction(0);
            SpvInstruction wrapper = context.Function(tVoid, FunctionControlMask.MaskNone, context.TypeFunction(tVoid, false));
            context.AddFunction(wrapper);
            context.AddLabel(context.Label());

            SpvInstruction Barrier() => context.ControlBarrier(U(2), U(2), U(0x108));   // Workgroup, Workgroup, AcquireRelease | WorkgroupMemory
            void Guarded(SpvInstruction cond, Action then)
            {
                SpvInstruction thenLabel = context.Label(), mergeLabel = context.Label();
                context.SelectionMerge(mergeLabel, SelectionControlMask.MaskNone);
                context.BranchConditional(cond, thenLabel, mergeLabel);
                context.AddLabel(thenLabel);
                then();
                context.Branch(mergeLabel);
                context.AddLabel(mergeLabel);
            }

            SpvInstruction pOutF32 = context.TypePointer(StorageClass.Output, tF32), pOutVec4 = context.TypePointer(StorageClass.Output, tVec4);
            SpvInstruction lid = context.Load(tU32, lidVar);
            SpvInstruction pPayload = context.TypePointer(StorageClass.TaskPayloadWorkgroupEXT, tU32);

            // Metal's threadgroup memory starts with whatever was there: a workgroup that leaves before writing its counts (task: mesh groups to launch; mesh: the header with the
            // primitive count) would hand Metal a garbage count. Both start at 0, as on the Switch 2
            if (mesh.IsTask)
            {
                context.Store(context.AccessChain(pPayload, payload, U(1)), U(0));
            }
            else
            {
                context.Store(context.AccessChain(context.TypePointer(StorageClass.Workgroup, tU32), context.SharedMemories[mesh.PrimitiveMemoryId], U(0)), U(0));

                // Every primitive's per-primitive outputs start as (0, 0, 0, 1); the program then writes its components straight into them (MeshPlaneStore below)
                if (primGenerics.Count != 0)
                {
                    for (int k = 0; k * threads < mesh.MaxPrimitives; k++)
                    {
                        SpvInstruction t = context.IAdd(tU32, lid, U((uint)(k * threads)));
                        Guarded(context.ULessThan(tBool, t, U((uint)mesh.MaxPrimitives)), () =>
                        {
                            foreach (SpvInstruction pv in primGenerics.Values)
                            {
                                context.Store(context.AccessChain(pOutVec4, pv, t), context.ConstantComposite(tVec4, context.Constant(tF32, 0f), context.Constant(tF32, 0f), context.Constant(tF32, 0f), context.Constant(tF32, 1f)));
                            }
                        });
                    }
                }
            }
            Barrier();

            context.FunctionCall(tVoid, body);
            Barrier();

            if (mesh.IsTask)
            {
                SpvInstruction count = context.Load(tU32, context.AccessChain(pPayload, payload, U(1)));
                count = context.Select(tU32, context.ULessThan(tBool, count, U(1024)), count, U(1024));   // Metal's limit of mesh groups per object group
                Barrier();   // every thread has read the count before word 0 changes
                context.Store(context.AccessChain(pPayload, payload, U(0)), U(0));
                Barrier();
                context.EmitMeshTasksEXT(count, U(1), U(1), payload);
            }
            else
            {
                SpvInstruction planes = context.SharedMemories[mesh.PlaneMemoryId], prims = context.SharedMemories[mesh.PrimitiveMemoryId];
                SpvInstruction pWg = context.TypePointer(StorageClass.Workgroup, tU32);
                SpvInstruction header = context.Load(tU32, context.AccessChain(pWg, prims, U(0)));
                SpvInstruction primCount = context.BitwiseAnd(tU32, context.ShiftRightLogical(tU32, header, U(24)), U(0xff));
                primCount = context.Select(tU32, context.ULessThan(tBool, primCount, U((uint)mesh.MaxPrimitives)), primCount, U((uint)mesh.MaxPrimitives));
                context.SetMeshOutputsEXT(U((uint)mesh.MaxVertices), primCount);

                SpvInstruction pOutUVec3 = context.TypePointer(StorageClass.Output, tUVec3);
                SpvInstruction Byte(SpvInstruction address)
                {
                    SpvInstruction w = context.BitwiseAnd(tU32, context.ShiftRightLogical(tU32, address, U(2)), U((uint)(mesh.PrimitiveWords - 1)));
                    SpvInstruction shift = context.IMul(tU32, context.BitwiseAnd(tU32, address, U(3)), U(8));
                    return context.BitwiseAnd(tU32, context.ShiftRightLogical(tU32, context.Load(tU32, context.AccessChain(pWg, prims, w)), shift), U(0xff));
                }

                for (int k = 0; k * threads < mesh.MaxPrimitives; k++)
                {
                    SpvInstruction t = context.IAdd(tU32, lid, U((uint)(k * threads)));
                    Guarded(context.ULessThan(tBool, t, primCount), () =>
                    {
                        SpvInstruction a = context.IAdd(tU32, context.IMul(tU32, t, U(3)), U(4));
                        SpvInstruction tri = context.CompositeConstruct(tUVec3, Byte(a), Byte(context.IAdd(tU32, a, U(1))), Byte(context.IAdd(tU32, a, U(2))));
                        context.Store(context.AccessChain(pOutUVec3, idxVar, t), tri);

                    });
                }

                context.Return();
            }

            context.FunctionEnd();

            // The mesh program's stores into its per-vertex / per-primitive values (MeshShaderInfo window 4, CodeGenContext.MeshPlaneStore), straight into the outputs: word w is
            // vertex (w / chunk) x 32 + w % 32, plane (w % chunk) / 32 below the per-primitive base, the same for primitives above it (chunk = 32 x planes)
            if (mesh.IsMesh && context.HasMeshPlaneStore)
            {
                SpvInstruction store = context.MeshPlaneStore;
                context.AddFunction(store);
                SpvInstruction word = context.FunctionParameter(tU32), value = context.FunctionParameter(tU32);
                context.AddLabel(context.Label());
                SpvInstruction f = context.Bitcast(tF32, value);

                void Scatter(SpvInstruction w, int chunkWords, int count, int[] planes, Func<SpvInstruction, int, SpvInstruction> target)
                {
                    if (chunkWords == 0)
                    {
                        return;
                    }

                    SpvInstruction rem = context.UMod(tU32, w, U((uint)chunkWords));
                    SpvInstruction plane = context.ShiftRightLogical(tU32, rem, U(5));
                    SpvInstruction index = context.IAdd(tU32, context.IMul(tU32, context.UDiv(tU32, w, U((uint)chunkWords)), U(32)), context.BitwiseAnd(tU32, rem, U(31)));
                    Guarded(context.ULessThan(tBool, index, U((uint)count)), () =>
                    {
                        for (int n = 0; n < planes.Length; n++)
                        {
                            SpvInstruction t = target(index, planes[n]);
                            if (t != null)
                            {
                                Guarded(context.IEqual(tBool, plane, U((uint)n)), () => context.Store(t, f));
                            }
                        }
                    });
                }

                SpvInstruction isVertex = context.ULessThan(tBool, word, U((uint)mesh.PrimitiveBaseWord));
                Guarded(isVertex, () => Scatter(word, mesh.VertexChunkWords, mesh.MaxVertices, mesh.Planes, (v, plane) => plane < 4
                    ? context.AccessChain(pOutF32, posVar, v, U(0), U((uint)plane))
                    : context.AccessChain(pOutF32, generics[(plane - 4) >> 2], v, U((uint)(plane & 3)))));
                Guarded(context.LogicalNot(tBool, isVertex), () => Scatter(context.ISub(tU32, word, U((uint)mesh.PrimitiveBaseWord)), mesh.PrimitiveChunkWords, mesh.MaxPrimitives, mesh.PrimitivePlanes,
                    (t, plane) => plane < 4 || !primGenerics.ContainsKey((plane - 4) >> 2) ? null : context.AccessChain(pOutF32, primGenerics[(plane - 4) >> 2], t, U((uint)(plane & 3)))));
                context.Return();
                context.FunctionEnd();
            }

            foreach (SpvInstruction global in context.GlobalVariables)   // SPIR-V 1.4: every global, not only the inputs and outputs
            {
                if (!io.Contains(global))
                {
                    io.Add(global);
                }
            }

            context.AddEntryPoint(mesh.IsTask ? ExecutionModel.TaskEXT : ExecutionModel.MeshEXT, wrapper, "main", io.ToArray());
            context.AddExecutionMode(wrapper, ExecutionMode.LocalSize,
                (SpvLiteralInteger)context.Definitions.ComputeLocalSizeX, (SpvLiteralInteger)context.Definitions.ComputeLocalSizeY, (SpvLiteralInteger)context.Definitions.ComputeLocalSizeZ);
            if (mesh.IsMesh)
            {
                context.AddExecutionMode(wrapper, ExecutionMode.OutputVertices, (SpvLiteralInteger)mesh.MaxVertices);
                context.AddExecutionMode(wrapper, ExecutionMode.OutputPrimitivesEXT, (SpvLiteralInteger)mesh.MaxPrimitives);
                context.AddExecutionMode(wrapper, ExecutionMode.OutputTrianglesEXT);
            }
        }

        private static void Generate(CodeGenContext context, StructuredProgramInfo info, int funcIndex)
        {
            (StructuredFunction function, SpvInstruction spvFunc) = context.GetFunction(funcIndex);

            context.CurrentFunction = function;
            context.AddFunction(spvFunc);
            context.StartFunction(isMainFunction: funcIndex == 0);

            Declarations.DeclareParameters(context, function);

            context.EnterBlock(function.MainBlock);

            Declarations.DeclareLocals(context, function);

            Generate(context, function.MainBlock);

            // Functions must always end with a return.
            if (function.MainBlock.Last is not AstOperation operation ||
                (operation.Inst != Instruction.Return && operation.Inst != Instruction.Discard))
            {
                context.Return();
            }

            context.FunctionEnd();

            if (funcIndex == 0 && context.Properties.Mesh == null)   // a task / mesh program's entry point is GenerateMeshEntry's wrapper
            {
                context.AddEntryPoint(context.Definitions.Stage.Convert(), spvFunc, "main", context.GetMainInterface());

                if (context.Definitions.Stage == ShaderStage.TessellationControl)
                {
                    context.AddExecutionMode(spvFunc, ExecutionMode.OutputVertices, (SpvLiteralInteger)context.Definitions.ThreadsPerInputPrimitive);
                }
                else if (context.Definitions.Stage == ShaderStage.TessellationEvaluation)
                {
                    switch (context.Definitions.TessPatchType)
                    {
                        case TessPatchType.Isolines:
                            context.AddExecutionMode(spvFunc, ExecutionMode.Isolines);
                            break;
                        case TessPatchType.Triangles:
                            context.AddExecutionMode(spvFunc, ExecutionMode.Triangles);
                            break;
                        case TessPatchType.Quads:
                            context.AddExecutionMode(spvFunc, ExecutionMode.Quads);
                            break;
                    }

                    switch (context.Definitions.TessSpacing)
                    {
                        case TessSpacing.EqualSpacing:
                            context.AddExecutionMode(spvFunc, ExecutionMode.SpacingEqual);
                            break;
                        case TessSpacing.FractionalEventSpacing:
                            context.AddExecutionMode(spvFunc, ExecutionMode.SpacingFractionalEven);
                            break;
                        case TessSpacing.FractionalOddSpacing:
                            context.AddExecutionMode(spvFunc, ExecutionMode.SpacingFractionalOdd);
                            break;
                    }

                    bool tessCw = context.Definitions.TessCw;

                    if (context.TargetApi == TargetApi.Vulkan)
                    {
                        // We invert the front face on Vulkan backend, so we need to do that here as well.
                        tessCw = !tessCw;
                    }

                    if (tessCw)
                    {
                        context.AddExecutionMode(spvFunc, ExecutionMode.VertexOrderCw);
                    }
                    else
                    {
                        context.AddExecutionMode(spvFunc, ExecutionMode.VertexOrderCcw);
                    }
                }
                else if (context.Definitions.Stage == ShaderStage.Geometry)
                {
                    context.AddExecutionMode(spvFunc, context.Definitions.InputTopology switch
                    {
                        InputTopology.Points => ExecutionMode.InputPoints,
                        InputTopology.Lines => ExecutionMode.InputLines,
                        InputTopology.LinesAdjacency => ExecutionMode.InputLinesAdjacency,
                        InputTopology.Triangles => ExecutionMode.Triangles,
                        InputTopology.TrianglesAdjacency => ExecutionMode.InputTrianglesAdjacency,
                        _ => throw new InvalidOperationException($"Invalid input topology \"{context.Definitions.InputTopology}\"."),
                    });

                    context.AddExecutionMode(spvFunc, ExecutionMode.Invocations, (SpvLiteralInteger)context.Definitions.ThreadsPerInputPrimitive);

                    context.AddExecutionMode(spvFunc, context.Definitions.OutputTopology switch
                    {
                        OutputTopology.PointList => ExecutionMode.OutputPoints,
                        OutputTopology.LineStrip => ExecutionMode.OutputLineStrip,
                        OutputTopology.TriangleStrip => ExecutionMode.OutputTriangleStrip,
                        _ => throw new InvalidOperationException($"Invalid output topology \"{context.Definitions.OutputTopology}\"."),
                    });

                    context.AddExecutionMode(spvFunc, ExecutionMode.OutputVertices, (SpvLiteralInteger)context.Definitions.MaxOutputVertices);
                }
                else if (context.Definitions.Stage == ShaderStage.Fragment)
                {
                    context.AddExecutionMode(spvFunc, context.Definitions.OriginUpperLeft
                        ? ExecutionMode.OriginUpperLeft
                        : ExecutionMode.OriginLowerLeft);

                    if (context.Info.IoDefinitions.Contains(new IoDefinition(StorageKind.Output, IoVariable.FragmentOutputDepth)))
                    {
                        context.AddExecutionMode(spvFunc, ExecutionMode.DepthReplacing);
                    }

                    if (context.Definitions.EarlyZForce)
                    {
                        context.AddExecutionMode(spvFunc, ExecutionMode.EarlyFragmentTests);
                    }

                    if ((info.HelperFunctionsMask & HelperFunctionsMask.FSI) != 0 &&
                        context.HostCapabilities.SupportsFragmentShaderInterlock)
                    {
                        context.AddExecutionMode(spvFunc, ExecutionMode.PixelInterlockOrderedEXT);
                    }
                }
                else if (context.Definitions.Stage == ShaderStage.Compute)
                {
                    SpvLiteralInteger localSizeX = (SpvLiteralInteger)context.Definitions.ComputeLocalSizeX;
                    SpvLiteralInteger localSizeY = (SpvLiteralInteger)context.Definitions.ComputeLocalSizeY;
                    SpvLiteralInteger localSizeZ = (SpvLiteralInteger)context.Definitions.ComputeLocalSizeZ;

                    context.AddExecutionMode(
                        spvFunc,
                        ExecutionMode.LocalSize,
                        localSizeX,
                        localSizeY,
                        localSizeZ);
                }

                if (context.Definitions.TransformFeedbackEnabled && context.Definitions.LastInVertexPipeline)
                {
                    context.AddExecutionMode(spvFunc, ExecutionMode.Xfb);
                }
            }
        }

        private static void Generate(CodeGenContext context, AstBlock block)
        {
            AstBlockVisitor visitor = new(block);

            Dictionary<AstBlock, (SpvInstruction, SpvInstruction)> loopTargets = new();

            context.LoopTargets = loopTargets;

            visitor.BlockEntered += (sender, e) =>
            {
                AstBlock mergeBlock = e.Block.Parent;

                if (e.Block.Type == AstBlockType.If)
                {
                    AstBlock ifTrueBlock = e.Block;
                    AstBlock ifFalseBlock;

                    if (AstHelper.Next(e.Block) is AstBlock nextBlock && nextBlock.Type == AstBlockType.Else)
                    {
                        ifFalseBlock = nextBlock;
                    }
                    else
                    {
                        ifFalseBlock = mergeBlock;
                    }

                    SpvInstruction condition = context.Get(AggregateType.Bool, e.Block.Condition);

                    context.SelectionMerge(context.GetNextLabel(mergeBlock), SelectionControlMask.MaskNone);
                    context.BranchConditional(condition, context.GetNextLabel(ifTrueBlock), context.GetNextLabel(ifFalseBlock));
                }
                else if (e.Block.Type == AstBlockType.DoWhile)
                {
                    SpvInstruction continueTarget = context.Label();

                    loopTargets.Add(e.Block, (context.NewBlock(), continueTarget));

                    context.LoopMerge(context.GetNextLabel(mergeBlock), continueTarget, LoopControlMask.MaskNone);
                    context.Branch(context.GetFirstLabel(e.Block));
                }

                context.EnterBlock(e.Block);
            };

            visitor.BlockLeft += (sender, e) =>
            {
                if (e.Block.Parent != null)
                {
                    if (e.Block.Type == AstBlockType.DoWhile)
                    {
                        // This is a loop, we need to jump back to the loop header
                        // if the condition is true.
                        AstBlock mergeBlock = e.Block.Parent;

                        (SpvInstruction loopTarget, SpvInstruction continueTarget) = loopTargets[e.Block];

                        context.Branch(continueTarget);
                        context.AddLabel(continueTarget);

                        SpvInstruction condition = context.Get(AggregateType.Bool, e.Block.Condition);

                        context.BranchConditional(condition, loopTarget, context.GetNextLabel(mergeBlock));
                    }
                    else
                    {
                        // We only need a branch if the last instruction didn't
                        // already cause the program to exit or jump elsewhere.
                        bool lastIsCf = e.Block.Last is AstOperation lastOp &&
                            (lastOp.Inst == Instruction.Discard ||
                             lastOp.Inst == Instruction.LoopBreak ||
                             lastOp.Inst == Instruction.LoopContinue ||
                             lastOp.Inst == Instruction.Return);

                        if (!lastIsCf)
                        {
                            context.Branch(context.GetNextLabel(e.Block.Parent));
                        }
                    }

                    bool hasElse = AstHelper.Next(e.Block) is AstBlock nextBlock &&
                        (nextBlock.Type == AstBlockType.Else ||
                         nextBlock.Type == AstBlockType.ElseIf);

                    // Re-enter the parent block.
                    if (e.Block.Parent != null && !hasElse)
                    {
                        context.EnterBlock(e.Block.Parent);
                    }
                }
            };

            foreach (IAstNode node in visitor.Visit())
            {
                if (node is AstAssignment assignment)
                {
                    AstOperand dest = (AstOperand)assignment.Destination;

                    if (dest.Type == OperandType.LocalVariable)
                    {
                        SpvInstruction source = context.Get(dest.VarType, assignment.Source);
                        context.Store(context.GetLocalPointer(dest), source);
                    }
                    else if (dest.Type == OperandType.Argument)
                    {
                        SpvInstruction source = context.Get(dest.VarType, assignment.Source);
                        context.Store(context.GetArgumentPointer(dest), source);
                    }
                    else
                    {
                        throw new NotImplementedException(dest.Type.ToString());
                    }
                }
                else if (node is AstOperation operation)
                {
                    Instructions.Generate(context, operation);
                }
            }
        }
    }
}
