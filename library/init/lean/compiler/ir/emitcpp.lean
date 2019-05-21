/-
Copyright (c) 2019 Microsoft Corporation. All rights reserved.
Released under Apache 2.0 license as described in the file LICENSE.
Authors: Leonardo de Moura
-/
prelude
import init.control.conditional
import init.lean.name_mangling
import init.lean.compiler.initattr
import init.lean.compiler.ir.compilerm
import init.lean.compiler.ir.emitutil
import init.lean.compiler.ir.normids

namespace Lean
namespace IR
@[extern "lean_get_export_name_for"]
constant getExportNameFor (env : @& Environment) (n : @& Name) : Option Name := default _

namespace EmitCpp

def leanMainFn := "_lean_main"

structure Context :=
(env        : Environment)
(modName    : Name)
(varMap     : VarTypeMap := {})
(jpMap      : JPParamsMap := {})
(mainFn     : FunId := default _)
(mainParams : Array Param := Array.empty)

abbrev M := ReaderT Context (EState String String)

def getEnv : M Environment := Context.env <$> read
def getModName : M Name := Context.modName <$> read
def getDecl (n : Name) : M Decl :=
do env ← getEnv,
   match findEnvDecl env n with
   | some d := pure d
   | none   := throw ("unknown declaration '" ++ toString n ++ "'")

@[inline] def emit {α : Type} [HasToString α] (a : α) : M Unit :=
modify (λ out, out ++ toString a)

@[inline] def emitLn {α : Type} [HasToString α] (a : α) : M Unit :=
emit a *> emit "\n"

@[inline] def emitVar (x : VarId) : M Unit :=
emit "x_" *> emit x.idx

def emitLns {α : Type} [HasToString α] (as : List α) : M Unit :=
as.mfor $ λ a, emitLn a

def emitArg (x : Arg) : M Unit :=
match x with
| Arg.var x := emitVar x
| _         := emit "lean::box(0)"

def emitLabel (j : JoinPointId) : M Unit :=
emit "lbl_" *> emit j.idx

def toCppType : IRType → String
| IRType.float      := "double"
| IRType.uint8      := "uint8"
| IRType.uint16     := "uint16"
| IRType.uint32     := "uint32"
| IRType.uint64     := "uint64"
| IRType.usize      := "usize"
| IRType.object     := "obj*"
| IRType.tobject    := "obj*"
| IRType.irrelevant := "obj*"

def openNamespacesAux : Name → M Unit
| Name.anonymous      := pure ()
| (Name.mkString p s) := openNamespacesAux p *> emitLn ("namespace " ++ s ++ " {")
| n                   := throw ("invalid namespace '" ++ toString n ++ "'")

def openNamespaces (n : Name) : M Unit :=
openNamespacesAux n.getPrefix

def openNamespacesFor (n : Name) : M Unit :=
do env ← getEnv,
   match getExportNameFor env n with
   | none   := pure ()
   | some n := openNamespaces n

def closeNamespacesAux : Name → M Unit
| Name.anonymous      := pure ()
| (Name.mkString p _) := emitLn "}" *> closeNamespacesAux p
| n                   := throw ("invalid namespace '" ++ toString n ++ "'")

def closeNamespaces (n : Name) : M Unit :=
closeNamespacesAux n.getPrefix

def closeNamespacesFor (n : Name) : M Unit :=
do env ← getEnv,
   match getExportNameFor env n with
   | none   := pure ()
   | some n := closeNamespaces n

def throwInvalidExportName {α : Type} (n : Name) : M α :=
throw ("invalid export name '" ++ toString n ++ "'")

def toBaseCppName (n : Name) : M String :=
do env ← getEnv,
   match getExportNameFor env n with
   | some (Name.mkString _ s) := pure s
   | some _                   := throwInvalidExportName n
   | none                     := if n == `main then pure leanMainFn else pure n.mangle

def toCppName (n : Name) : M String :=
do env ← getEnv,
   match getExportNameFor env n with
   | some s := pure (s.toStringWithSep "::")
   | none   := if n == `main then pure leanMainFn else pure n.mangle

def toCppInitName (n : Name) : M String :=
do env ← getEnv,
   match getExportNameFor env n with
   | some (Name.mkString p s) := pure $ (Name.mkString p ("_init_" ++ s)).toStringWithSep "::"
   | some _                   := throwInvalidExportName n
   | none                     := pure ("_init_" ++ n.mangle)

def emitFnDeclAux (decl : Decl) (cppBaseName : String) (addExternForConsts : Bool) : M Unit :=
do
let ps := decl.params,
when (ps.isEmpty && addExternForConsts) (emit "extern "),
emit (toCppType decl.resultType ++ " " ++ cppBaseName),
unless (ps.isEmpty) $ do {
  emit "(",
  ps.size.mfor $ λ i, do {
    when (i > 0) (emit ", "),
    emit (toCppType (ps.get i).ty)
  },
  emit ")"
},
emitLn ";"

def emitFnDecl (decl : Decl) (addExternForConsts : Bool) : M Unit :=
do
openNamespacesFor decl.name,
cppBaseName ← toBaseCppName decl.name,
emitFnDeclAux decl cppBaseName addExternForConsts,
closeNamespacesFor decl.name

def cppQualifiedNameToName (s : String) : Name :=
(s.split "::").foldl Name.mkString Name.anonymous

def emitExternDeclAux (decl : Decl) (cppName : String) : M Unit :=
do
let qCppName := cppQualifiedNameToName cppName,
openNamespaces qCppName,
env ← getEnv,
let extC := isExternC env decl.name,
when extC (emit "extern \"C\" "),
(Name.mkString _ qCppBaseName) ← pure qCppName | throw "invalid name",
emitFnDeclAux decl qCppBaseName (!extC),
closeNamespaces qCppName

def emitFnDecls : M Unit :=
do
env ← getEnv,
let decls := getDecls env,
let modDecls  : NameSet := decls.foldl (λ s d, s.insert d.name) {},
let usedDecls : NameSet := decls.foldl (λ s d, collectUsedDecls d (s.insert d.name)) {},
let usedDecls := usedDecls.toList,
usedDecls.mfor $ λ n, do
  decl ← getDecl n,
  match getExternNameFor env `cpp decl.name with
  | some cppName := emitExternDeclAux decl cppName
  | none         := emitFnDecl decl (!modDecls.contains n)

def emitMainFn : M Unit :=
do
d ← getDecl `main,
match d with
| Decl.fdecl f xs t b := do
  unless (xs.size == 2 || xs.size == 1) (throw "invalid main function, incorrect arity when generating code"),
  env ← getEnv,
  let usesLeanAPI := usesLeanNamespace env d,
  when usesLeanAPI (emitLn "namespace lean { void initialize(); }"),
  emitLn "int main(int argc, char ** argv) {",
  if usesLeanAPI then
    emitLn "lean::initialize();"
  else
    emitLn "lean::initialize_runtime_module();",
  emitLn "obj * w = lean::io_mk_world();",
  modName ← getModName,
  emitLn ("w = initialize_" ++ (modName.mangle "") ++ "(w);"),
  emitLns ["lean::io_mark_end_initialization();",
           "if (io_result_is_ok(w)) {",
           "lean::scoped_task_manager tmanager(lean::hardware_concurrency());"],
  if xs.size == 2 then do {
    emitLns ["obj* in = lean::box(0);",
             "int i = argc;",
             "while (i > 1) {",
             " i--;",
             " obj* n = lean::alloc_cnstr(1,2,0); lean::cnstr_set(n, 0, lean::mk_string(argv[i])); lean::cnstr_set(n, 1, in);",
             " in = n;",
             "}"],
    emitLn ("w = " ++ leanMainFn ++ "(in, w);")
  } else do {
    emitLn ("w = " ++ leanMainFn ++ "(w);")
  },
  emitLn "}",
  emitLns ["if (io_result_is_ok(w)) {",
           "  int ret = lean::unbox(io_result_get_value(w));",
           "  lean::dec_ref(w);",
           "  return ret;",
           "} else {",
           "  lean::io_result_show_error(w);",
           "  lean::dec_ref(w);",
           "  return 1;",
           "}"],
  emitLn "}"
| other := throw "function declaration expected"

def hasMainFn : M Bool :=
do env ← getEnv,
   let decls := getDecls env,
   pure $ decls.any (λ d, d.name == `main)

def emitMainFnIfNeeded : M Unit :=
mwhen hasMainFn emitMainFn

def emitFileHeader : M Unit :=
do
env ← getEnv,
modName ← getModName,
emitLn "// Lean compiler output",
emitLn ("// Module: " ++ toString modName),
emit "// Imports:",
env.imports.mfor $ λ m, emit (" " ++ toString m),
emitLn "",
emitLn "#include \"runtime/object.h\"",
emitLn "#include \"runtime/apply.h\"",
mwhen hasMainFn $ emitLn "#include \"runtime/init_module.h\"",
emitLns [
 "typedef lean::object obj;    typedef lean::usize  usize;",
 "typedef lean::uint8  uint8;  typedef lean::uint16 uint16;",
 "typedef lean::uint32 uint32; typedef lean::uint64 uint64;",
 "#if defined(__clang__)",
 "#pragma clang diagnostic ignored \"-Wunused-parameter\"",
 "#pragma clang diagnostic ignored \"-Wunused-label\"",
 "#elif defined(__GNUC__) && !defined(__CLANG__)",
 "#pragma GCC diagnostic ignored \"-Wunused-parameter\"",
 "#pragma GCC diagnostic ignored \"-Wunused-label\"",
 "#pragma GCC diagnostic ignored \"-Wunused-but-set-variable\"",
 "#endif"]

def isIf (alts : Array Alt) : Option (Nat × FnBody × FnBody) :=
if alts.size != 2 then none
else match alts.get 0 with
  | Alt.ctor c b := some (c.cidx, b, (alts.get 1).body)
  | _            := none

def throwUnknownVar {α : Type} (x : VarId) : M α :=
throw ("unknown variable '" ++ toString x ++ "'")

def isObj (x : VarId) : M Bool :=
do ctx ← read,
   match ctx.varMap.find x with
   | some t := pure t.isObj
   | none   := throwUnknownVar x

def getJPParams (j : JoinPointId) : M (Array Param) :=
do ctx ← read,
   match ctx.jpMap.find j with
   | some ps := pure ps
   | none    := throw "unknown join point"

def declareVar (x : VarId) (t : IRType) : M Unit :=
do emit (toCppType t), emit " ", emitVar x, emit "; "

def declareParams (ps : Array Param) : M Unit :=
ps.mfor $ λ p, declareVar p.x p.ty

partial def declareVars : FnBody → Bool → M Bool
| (FnBody.vdecl x t _ b)  d := declareVar x t *> declareVars b true
| (FnBody.jdecl j xs _ b) d := declareParams xs *> declareVars b (d || xs.size > 0)
| e                       d := if e.isTerminal then pure d else declareVars e.body d

partial def emitCase (emitBody : FnBody → M Unit) (x : VarId) (alts : Array Alt) : M Unit :=
match isIf alts with
| some (tag, t, e) := do
  emit "if (", emitVar x, emit " == ", emit tag, emitLn ")",
  emitBody t,
  emitLn "else",
  emitBody e
| _ := do
  xIsObj ← isObj x,
  if xIsObj then do {
    emit "switch (lean::obj_tag(", emitVar x, emitLn ")) {"
  } else do {
    emit "switch (", emitVar x, emitLn ") {"
  },
  alts.mfor $ λ alt, match alt with
    | Alt.ctor c b  := emit "case " *> emit c.cidx *> emitLn ":" *> emitBody b
    | Alt.default b := emitLn "default: " *> emitBody b,
  emitLn "}"

def emitInc (x : VarId) (n : Nat) (checkRef : Bool) : M Unit :=
do
emit (if checkRef then "lean::inc" else "lean::inc_ref"),
emit "(" *> emitVar x,
when (n != 1) (emit ", " *> emit n),
emitLn ");"

def emitDec (x : VarId) (n : Nat) (checkRef : Bool) : M Unit :=
do
emit (if checkRef then "lean::dec" else "lean::dec_ref"),
emit "(" *> emitVar x,
when (n != 1) (emit ", " *> emit n),
emitLn ");"

def emitRelease (x : VarId) (i : Nat) : M Unit :=
do emit "lean::cnstr_release(", emitVar x, emit ", ", emit i, emitLn ");"

def emitSet (x : VarId) (i : Nat) (y : VarId) : M Unit :=
do emit "lean::cnstr_set(", emitVar x, emit ", ", emit i, emit ", ", emitVar y, emitLn ");"

def emitOffset (n : Nat) (offset : Nat) : M Unit :=
if n > 0 then do
  emit "sizeof(void*)*", emit n,
  when (offset > 0) (emit " + " *> emit offset)
else
  emit offset

def emitUSet (x : VarId) (n : Nat) (y : VarId) : M Unit :=
do emit "lean::cnstr_set_scalar(", emitVar x, emit ", ", emitOffset n 0, emit ", ", emitVar y, emitLn ");"

def emitSSet (x : VarId) (n : Nat) (offset : Nat) (y : VarId) : M Unit :=
do emit "lean::cnstr_set_scalar(", emitVar x, emit ", ", emitOffset n offset, emit ", ", emitVar y, emitLn ");"

def emitJmp (j : JoinPointId) (xs : Array Arg) : M Unit :=
do
  ps ← getJPParams j,
  unless (xs.size == ps.size) (throw "invalid goto"),
  xs.size.mfor $ λ i, do {
    let p := ps.get i,
    let x := xs.get i,
    emitVar p.x, emit " = ", emitArg x, emitLn ";"
  },
  emit "goto ", emitLabel j, emitLn ";"

def emitVDecl (x : VarId) (v : Expr) : M Unit :=
pure () -- TODO

partial def emitBlock (emitBody : FnBody → M Unit) : FnBody → M Unit
| (FnBody.jdecl j xs v b)   := emitBlock b
| (FnBody.vdecl x _ v b)    := emitVDecl x v *> emitBlock b
| (FnBody.inc x n c b)      := emitInc x n c *> emitBlock b
| (FnBody.dec x n c b)      := emitDec x n c *> emitBlock b
| (FnBody.release x i b)    := emitRelease x i *> emitBlock b
| (FnBody.set x i y b)      := emitSet x i y *> emitBlock b
| (FnBody.uset x i y b)     := emitUSet x i y *> emitBlock b
| (FnBody.sset x i o y _ b) := emitSSet x i o y *> emitBlock b
| (FnBody.mdata _ b)        := emitBlock b
| (FnBody.ret x)            := emit "return " *> emitArg x *> emitLn ";"
| (FnBody.case _ x alts)    := emitCase emitBody x alts
| (FnBody.jmp j xs)         := emitJmp j xs
| FnBody.unreachable        := emitLn "lean_unreachable();"

partial def emitJPs (emitBody : FnBody → M Unit) : FnBody → M Unit
| (FnBody.jdecl j xs v b) := do emitLabel j, emitLn ":", emitBody v, emitJPs b
| e                       := unless e.isTerminal (emitJPs e.body)

partial def emitFnBody : FnBody → M Unit
| b := do
emitLn "{",
declared ← declareVars b false,
when declared (emitLn ""),
emitBlock emitFnBody b,
emitJPs emitFnBody b,
emitLn "}"

def emitDeclAux (d : Decl) : M Unit :=
do
env ← getEnv,
let (vMap, jpMap) := mkVarJPMaps d,
adaptReader (λ ctx : Context, { varMap := vMap, jpMap := jpMap, .. ctx }) $ do
unless (hasInitAttr env d.name) $
  match d with
  | Decl.fdecl f xs t b := do
    openNamespacesFor f,
    baseName ← toBaseCppName f,
    emit (toCppType t), emit " ",
    if xs.size > 0 then do {
      emit baseName,
      emit "(",
      xs.size.mfor $ λ i, do {
        when (i > 0) (emit ", "),
        let x := xs.get i,
        emit (toCppType x.ty), emit " ", emitVar(x.x)
      },
      emit ")"
    } else do {
      emit ("_init_" ++ baseName ++ "()")
    },
    emitLn " {",
    emitLn "_start:",
    adaptReader (λ ctx : Context, { mainFn := f, mainParams := xs, .. ctx }) (emitFnBody b),
    emitLn "}",
    closeNamespacesFor f
  | _ := pure ()

def emitDecl (d : Decl) : M Unit :=
let d := d.normalizeIds in
catch
  (emitDeclAux d)
  (λ err, throw (err ++ "\ncompiling:\n" ++ toString d))

def emitFns : M Unit :=
do
env ← getEnv,
let decls := getDecls env,
decls.reverse.mfor emitDecl

def main : M Unit :=
do
emitFileHeader,
emitFnDecls,
emitFns,
emitMainFnIfNeeded

end EmitCpp

@[export lean.ir.emit_cpp_core]
def emitCpp (env : Environment) (modName : Name) : Except String String :=
match (EmitCpp.main { env := env, modName := modName }).run "" with
| EState.Result.ok    _   s := Except.ok s
| EState.Result.error err _ := Except.error err

end IR
end Lean
