// Copyright (c) 2024, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'package:analyzer/file_system/file_system.dart';
import 'package:dartdoc_vitepress/src/dartdoc.dart' show Dartdoc;
import 'package:dartdoc_vitepress/src/dartdoc_options.dart';
import 'package:dartdoc_vitepress/src/io_utils.dart';
import 'package:dartdoc_vitepress/src/logging.dart';
import 'package:dartdoc_vitepress/src/model/package_builder.dart';
import 'package:dartdoc_vitepress/src/package_meta.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../src/utils.dart';

final _resourceProvider = pubPackageMetaProvider.resourceProvider;
final _pathContext = _resourceProvider.pathContext;

Folder _getFolder(String path) => _resourceProvider
    .getFolder(_pathContext.absolute(_pathContext.canonicalize(path)));

final _testPackageDir = _getFolder('testing/test_package');
final _testPackageWithDocsDir = _getFolder('testing/test_package_with_docs');
final _testPackageExperimentsDir =
    _getFolder('testing/test_package_experiments');

Dartdoc _buildVitePressDartdoc(
    List<String> extraArgv, Folder pkgRoot, Folder outDir) {
  var context = generatorContextFromArgv([
    '--format',
    'vitepress',
    '--exclude-packages=args',
    ...extraArgv,
    '--input',
    pkgRoot.path,
    '--output',
    outDir.path,
  ], pubPackageMetaProvider);

  return Dartdoc.fromContext(
    context,
    PubPackageBuilder(context, pubPackageMetaProvider,
        skipUnreachableSdkLibraries: true),
  );
}

/// Reads a file relative to [outDir] and returns its content.
String _readOutput(Folder outDir, String relativePath) {
  final file =
      _resourceProvider.getFile(p.normalize(p.join(outDir.path, relativePath)));
  expect(file.exists, isTrue, reason: 'Expected file to exist: $relativePath');
  return file.readAsStringSync();
}

/// Returns true if a file exists relative to [outDir].
bool _outputExists(Folder outDir, String relativePath) {
  return _resourceProvider
      .getFile(p.normalize(p.join(outDir.path, relativePath)))
      .exists;
}

/// Returns true if a directory exists relative to [outDir].
bool _dirExists(Folder outDir, String relativePath) {
  return _resourceProvider
      .getFolder(p.normalize(p.join(outDir.path, relativePath)))
      .exists;
}

void main() {
  group('VitePress generator e2e', () {
    setUpAll(() async {
      var optionSet = DartdocOptionRoot.fromOptionGenerators(
          'dartdoc',
          [createDartdocProgramOptions, createLoggingOptions],
          pubPackageMetaProvider);
      optionSet.parseArguments([]);
      startLogging(isJson: false, isQuiet: true, showProgress: false);

      // test_package already has pub get from the main dartdoc test suite.
      runPubGet(_testPackageWithDocsDir.path);
    });

    // -----------------------------------------------------------------------
    // Group 1: test_package output (shared single generation)
    //
    // Combines basic structure, content quality, and edge-case checks that
    // are all read-only against the same generated output.
    // -----------------------------------------------------------------------
    group('test_package output', () {
      late final Folder outDir;

      setUpAll(() async {
        outDir = _resourceProvider.createSystemTemp('vitepress_e2e.');
        var dartdoc = _buildVitePressDartdoc([], _testPackageDir, outDir);
        await dartdoc.generateDocs();
      });

      tearDownAll(() {
        outDir.delete();
      });

      // -- File structure --------------------------------------------------

      test('api/index.md contains package name', () {
        var content = _readOutput(outDir, 'api/index.md');
        expect(content, contains('test_package'));
      });

      test('library page exists for ex', () {
        expect(_outputExists(outDir, 'api/ex/index.md'), isTrue);
      });

      test('class page exists and contains class heading', () {
        expect(_outputExists(outDir, 'api/ex/Apple.md'), isTrue);
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, matches(RegExp(r'^# Apple', multiLine: true)));
      });

      test('api-sidebar.ts is valid TypeScript export', () {
        var content =
            _readOutput(outDir, '.vitepress/generated/api-sidebar.ts');
        expect(content, contains('export'));
        expect(content, contains('apiSidebar'));
      });

      test('guide-sidebar.ts exists', () {
        expect(_outputExists(outDir, '.vitepress/generated/guide-sidebar.ts'),
            isTrue);
      });

      test('scaffold files are generated', () {
        expect(_outputExists(outDir, 'package.json'), isTrue);
        expect(_outputExists(outDir, '.vitepress/config.ts'), isTrue);
        expect(_outputExists(outDir, 'index.md'), isTrue);
        expect(_outputExists(outDir, 'guide/index.md'), isTrue);
      });

      test('DartPad component is scaffolded', () {
        expect(
          _outputExists(outDir, '.vitepress/theme/components/DartPad.vue'),
          isTrue,
        );
      });

      test('theme index.ts imports DartPad', () {
        var content = _readOutput(outDir, '.vitepress/theme/index.ts');
        expect(content, contains('DartPad'));
        expect(content, contains('enhanceApp'));
      });

      test('no member subdirectories (members are inline)', () {
        expect(_dirExists(outDir, 'api/ex/Apple'), isFalse);
      });

      test('multiple libraries generate separate directories', () {
        expect(_outputExists(outDir, 'api/ex/index.md'), isTrue);
        expect(_outputExists(outDir, 'api/fake/index.md'), isTrue);
      });

      // -- Class page content ----------------------------------------------

      test('class page has YAML frontmatter', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, startsWith('---'));
        expect(content, contains('title:'));
        expect(content, contains('editLink: false'));
      });

      test('frontmatter does not contain lastUpdated: false', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, isNot(contains('lastUpdated: false')));
      });

      test('regular class has no modifier badges in h1 heading', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        // Apple is a regular class — no modifier badges on the h1 heading.
        // (Member-level badges like "inherited" on h3 are expected.)
        final h1Line = content
            .split('\n')
            .firstWhere((l) => l.startsWith('# '), orElse: () => '');
        expect(h1Line, isNot(contains('<Badge type="info"')));
      });

      test('class page has Constructors section', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('## Constructors'));
      });

      test('class page has Methods section', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('## Methods'));
      });

      test('class page has declaration code block and member signatures', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        // Container declaration still uses ```dart code blocks
        expect(content, contains('```dart'));
        // Member signatures use HTML with clickable type links
        expect(content, contains('member-signature'));
      });

      // -- Library page content --------------------------------------------

      test('library page has Classes grouping', () {
        var content = _readOutput(outDir, 'api/ex/index.md');
        expect(content, contains('## Classes'));
      });

      test('library page contains markdown cross-links', () {
        var content = _readOutput(outDir, 'api/ex/index.md');
        expect(content, contains('[Apple](/api/ex/Apple)'));
      });

      // -- Sidebar content -------------------------------------------------

      test('sidebar has per-library base paths', () {
        var content =
            _readOutput(outDir, '.vitepress/generated/api-sidebar.ts');
        expect(content, contains("base: '/api/ex/'"));
        expect(content, contains("base: '/api/fake/'"));
      });

      // -- Enum page -------------------------------------------------------

      test('enum page exists and has Values section', () {
        var content = _readOutput(outDir, 'api/fake/MacrosFromAccessors.md');
        expect(content,
            matches(RegExp(r'^# MacrosFromAccessors', multiLine: true)));
        expect(content, contains('## Values'));
      });

      // -- Mixin page ------------------------------------------------------

      test('mixin page exists and has Superclass Constraints', () {
        var content =
            _readOutput(outDir, 'api/fake/NewStyleMixinCallingSuper.md');
        expect(content,
            matches(RegExp(r'^# NewStyleMixinCallingSuper', multiLine: true)));
        expect(content, contains(':::info Superclass Constraints'));
      });

      test('mixin page has Implementers section when implemented', () {
        // GenericMixin is used by classes — should have Implementers
        var content = _readOutput(outDir, 'api/fake/GenericMixin.md');
        expect(content, contains(':::info Implementers'));
      });

      // -- Extension page --------------------------------------------------

      test('extension page exists and mentions extended type', () {
        var content = _readOutput(outDir, 'api/ex/AppleExtension.md');
        expect(content, matches(RegExp(r'^# AppleExtension', multiLine: true)));
        // Extension declaration should mention Apple
        expect(content, contains('Apple'));
      });

      // -- Typedef page ----------------------------------------------------

      test('typedef page exists', () {
        expect(_outputExists(outDir, 'api/fake/VoidCallback.md'), isTrue);
        var content = _readOutput(outDir, 'api/fake/VoidCallback.md');
        expect(content, matches(RegExp(r'^# VoidCallback', multiLine: true)));
      });

      // -- Top-level function page -----------------------------------------

      test('function page exists with signature', () {
        expect(_outputExists(outDir, 'api/ex/testMacro.md'), isTrue);
        var content = _readOutput(outDir, 'api/ex/testMacro.md');
        expect(content, matches(RegExp(r'^# testMacro', multiLine: true)));
        expect(content, contains('member-signature'));
      });

      // -- Top-level property page -----------------------------------------

      test('top-level constant page exists', () {
        expect(_outputExists(outDir, 'api/ex/COLOR.md'), isTrue);
        var content = _readOutput(outDir, 'api/ex/COLOR.md');
        expect(content, matches(RegExp(r'^# COLOR', multiLine: true)));
      });

      // -- Deprecated rendering --------------------------------------------

      test('deprecated class has deprecated badge and notice', () {
        // SuperAwesomeClass in fake library is @deprecated
        var content = _readOutput(outDir, 'api/fake/SuperAwesomeClass.md');
        // H1 heading should have strikethrough and badge
        expect(content, contains('<Badge type="warning" text="deprecated" />'));
        expect(content, contains('~~SuperAwesomeClass~~'));
        // Deprecation notice block
        expect(content, contains(':::warning DEPRECATED'));
      });

      // -- Category page content -------------------------------------------

      test('category page exists with content', () {
        // test_package: category "Excellent" has displayName "Superb"
        var content = _readOutput(outDir, 'topics/Superb.md');
        expect(content, matches(RegExp(r'^# Superb', multiLine: true)));
      });

      // -- Package overview ------------------------------------------------

      test('package overview contains Libraries section', () {
        var content = _readOutput(outDir, 'api/index.md');
        expect(content, contains('## Libraries'));
      });

      // -- Class with operators --------------------------------------------

      test('class with operators has Operators section', () {
        // SpecialList<E> in fake has operator[] and operator[]=
        var content = _readOutput(outDir, 'api/fake/SpecialList.md');
        expect(content, contains('## Operators'));
      });

      // -- Class with named constructors -----------------------------------

      test('class with multiple constructors lists them all', () {
        // LongFirstLine in fake has default + fromMap + fromHasGenerics
        var content = _readOutput(outDir, 'api/fake/LongFirstLine.md');
        expect(content, contains('## Constructors'));
        expect(content, contains('fromMap'));
        expect(content, contains('fromHasGenerics'));
      });

      // -- Generic class ---------------------------------------------------

      test('generic class page handles type parameters', () {
        // HasGenerics<X, Y, Z> in fake
        var content = _readOutput(outDir, 'api/fake/HasGenerics.md');
        expect(content, matches(RegExp(r'^# HasGenerics', multiLine: true)));
        // Declaration should contain generic params
        expect(content, contains('```dart'));
      });

      // -- Class with properties -------------------------------------------

      test('class with properties has Properties section', () {
        // ImplicitProperties in fake has getters/setters
        var content = _readOutput(outDir, 'api/fake/ImplicitProperties.md');
        expect(content, contains('## Properties'));
      });

      // -- Class with inheritance ------------------------------------------

      test('class declaration shows extends clause', () {
        // BoxConstraints extends Constraints in override_class
        var content =
            _readOutput(outDir, 'api/override_class/BoxConstraints.md');
        expect(content, matches(RegExp(r'^# BoxConstraints', multiLine: true)));
        expect(content, contains('extends'));
        expect(content, contains('Constraints'));
      });

      // -- Abstract class --------------------------------------------------

      test('abstract class declaration', () {
        // Constraints is abstract in base_class
        var content = _readOutput(outDir, 'api/base_class/Constraints.md');
        expect(content, matches(RegExp(r'^# Constraints', multiLine: true)));
        expect(content, contains('abstract'));
      });

      test('abstract class has abstract badge in heading', () {
        var content = _readOutput(outDir, 'api/base_class/Constraints.md');
        expect(content, contains('<Badge type="info" text="abstract" />'));
      });

      // -- Class with implements -------------------------------------------

      test('class declaration shows implements clause', () {
        // LongFirstLine implements Interface, AnotherInterface
        var content = _readOutput(outDir, 'api/fake/LongFirstLine.md');
        expect(content, contains('implements'));
      });

      // -- Class with static members ---------------------------------------

      test('class with static members has static sections', () {
        // LongFirstLine in fake has static methods, static properties,
        // and constants
        var content = _readOutput(outDir, 'api/fake/LongFirstLine.md');
        expect(content, contains('## Static Methods'));
        expect(content, contains('## Constants'));
      });

      // -- Top-level function with parameters ------------------------------

      test('function page renders parameters in signature', () {
        // topLevelFunction in fake has multiple params (it's also deprecated)
        var content = _readOutput(outDir, 'api/fake/topLevelFunction.md');
        expect(content,
            matches(RegExp(r'^# .*~~?topLevelFunction~~?', multiLine: true)));
        expect(content, contains('member-signature'));
        // Signature should mention parameter names
        expect(content, contains('param1'));
        expect(content, contains('param2'));
      });

      // -- Deprecated typedef ----------------------------------------------

      test('deprecated typedef has deprecated badge', () {
        // FakeProcesses in fake is @deprecated
        var content = _readOutput(outDir, 'api/fake/FakeProcesses.md');
        expect(content, contains('<Badge type="warning" text="deprecated" />'));
        expect(content, contains(':::warning DEPRECATED'));
      });

      // -- Deprecated top-level constant -----------------------------------

      test('deprecated constant has deprecated badge', () {
        // DOWN in fake is @deprecated
        var content = _readOutput(outDir, 'api/fake/DOWN.md');
        expect(content, contains('<Badge type="warning" text="deprecated" />'));
      });

      // -- Library overview tables -----------------------------------------

      test('library page has Enums section', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        expect(content, contains('## Enums'));
      });

      test('library page has Extensions section', () {
        var content = _readOutput(outDir, 'api/ex/index.md');
        expect(content, contains('## Extensions'));
      });

      test('library page has Functions section', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        expect(content, contains('## Functions'));
      });

      test('library page has Properties section', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        expect(content, contains('## Properties'));
      });

      test('library page has Constants section', () {
        var content = _readOutput(outDir, 'api/ex/index.md');
        expect(content, contains('## Constants'));
      });

      test('library page has Typedefs section', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        expect(content, contains('## Typedefs'));
      });

      test('library page has Mixins section', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        expect(content, contains('## Mixins'));
      });

      // -- Deprecated elements in library tables ---------------------------

      test('library table shows deprecated elements with strikethrough', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        // Deprecated class should appear with strikethrough in the table
        expect(content, contains('~~'));
        // SuperAwesomeClass is deprecated and should be linked
        expect(content, contains('SuperAwesomeClass'));
      });

      // -- Frontmatter on all page types -----------------------------------

      test('library page has frontmatter', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        expect(content, startsWith('---'));
        expect(content, contains('title:'));
        expect(content, contains('editLink: false'));
      });

      test('function page has frontmatter', () {
        var content = _readOutput(outDir, 'api/fake/topLevelFunction.md');
        expect(content, startsWith('---'));
        expect(content, contains('editLink: false'));
      });

      test('enum page has frontmatter', () {
        var content = _readOutput(outDir, 'api/fake/MacrosFromAccessors.md');
        expect(content, startsWith('---'));
        expect(content, contains('editLink: false'));
      });

      // -- README in package overview --------------------------------------

      test('package overview includes README content', () {
        // test_package has README.md with "# Best Package"
        var content = _readOutput(outDir, 'api/index.md');
        expect(content, contains('Best Package'));
      });

      // -- Category page with categorized elements -------------------------

      test('category page lists categorized elements', () {
        var content = _readOutput(outDir, 'topics/Superb.md');
        // Category "Excellent" (displayName "Superb") should list
        // elements that have @category Excellent
        expect(content, contains('## Classes'));
      });

      // -- Sidebar structure -----------------------------------------------

      test('sidebar contains library entries with items', () {
        var content =
            _readOutput(outDir, '.vitepress/generated/api-sidebar.ts');
        // Sidebar should list class names as items
        expect(content, contains('Apple'));
        expect(content, contains('Dog'));
      });

      // -- Class with mixin ------------------------------------------------

      test('class declaration shows with clause for mixins', () {
        // GenericMixin on GenericClass<T> in fake
        var content = _readOutput(outDir, 'api/fake/GenericMixin.md');
        expect(content, matches(RegExp(r'^# GenericMixin', multiLine: true)));
      });

      // -- Extension declaration -------------------------------------------

      test('extension page declaration contains on keyword', () {
        var content = _readOutput(outDir, 'api/ex/AppleExtension.md');
        // Declaration code block should have "extension AppleExtension on Apple"
        expect(content, contains('on'));
        expect(content, contains('Apple'));
      });

      // -- Private members should NOT appear ---------------------------------

      test('private extension does NOT generate page', () {
        expect(_outputExists(outDir, 'api/ex/_Shhh.md'), isFalse);
      });

      test('private class does NOT generate page', () {
        expect(
            _outputExists(outDir, 'api/fake/_APrivateConstClass.md'), isFalse);
      });

      // -- Inherited members -------------------------------------------------

      test('inherited method shows provenance notice', () {
        var content = _readOutput(outDir, 'api/fake/InheritingClassOne.md');
        // aMethod is inherited from _PrivateClassDefiningSomething
        expect(content, contains('### aMethod()'));
        expect(content,
            contains('*Inherited from _PrivateClassDefiningSomething.*'));
      });

      test('inherited Object members show Inherited from Object', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('*Inherited from Object.*'));
      });

      // -- Factory constructor -----------------------------------------------

      test('factory constructor shows factory keyword', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('### Apple.fromString()'));
        // Signature is now HTML with <span class="kw"> for keywords
        expect(content, contains('member-signature'));
        expect(content, contains('<span class="kw">factory</span>'));
        expect(content, contains('Apple.fromString'));
      });

      // -- Const constructors ------------------------------------------------

      test('const constructor shows const keyword', () {
        var content = _readOutput(outDir, 'api/fake/ConstantClass.md');
        // Signature uses HTML spans for keywords
        expect(content, contains('<span class="kw">const</span>'));
        expect(content, contains('ConstantClass('));
      });

      test('named const constructor renders correctly', () {
        var content = _readOutput(outDir, 'api/fake/ConstantClass.md');
        expect(content, contains('### ConstantClass.isVeryConstant()'));
        expect(content, contains('ConstantClass.isVeryConstant('));
      });

      test('non-const named constructor lacks const keyword', () {
        var content = _readOutput(outDir, 'api/fake/ConstantClass.md');
        expect(content, contains('### ConstantClass.notConstant()'));
        expect(content, contains('ConstantClass.notConstant('));
      });

      // -- Operator signatures -----------------------------------------------

      test('operator [] and []= render with correct signatures', () {
        var content = _readOutput(outDir, 'api/fake/SpecialList.md');
        expect(content, contains('### operator []()'));
        // Signatures are now in member-signature HTML blocks
        expect(content, contains('operator []('));
        expect(content, contains('### operator []=()'));
        expect(content, contains('operator []=('));
      });

      test('operator == renders correctly', () {
        var content = _readOutput(outDir, 'api/fake/OperatorReferenceClass.md');
        expect(content, contains('### operator ==()'));
        expect(content, contains('operator ==('));
      });

      test('inherited operators appear in child class', () {
        var content = _readOutput(outDir, 'api/fake/ExtraSpecialList.md');
        expect(content, contains('## Operators'));
        // ExtraSpecialList extends SpecialList, inherits operator []
      });

      test('unary operator renders correctly', () {
        var content = _readOutput(outDir, 'api/fake/SpecialList.md');
        expect(content, contains('### operator unary-()'));
      });

      // -- Generic type parameters in heading --------------------------------

      test('generic class heading escapes angle brackets', () {
        var content = _readOutput(outDir, 'api/fake/HasGenerics.md');
        expect(content, contains(r'# HasGenerics\<X, Y, Z\>'));
      });

      test('generic class declaration shows type parameters', () {
        var content = _readOutput(outDir, 'api/fake/HasGenerics.md');
        expect(content, contains('class HasGenerics<X, Y, Z>'));
      });

      test('generic methods preserve type parameters in return type', () {
        var content = _readOutput(outDir, 'api/fake/HasGenerics.md');
        // Signatures now use HTML with &lt; &gt; for angle brackets
        expect(content, contains('convertToMap()'));
        expect(content, contains('doStuff('));
      });

      // -- Generic extension -------------------------------------------------

      test('generic extension heading and declaration', () {
        var content = _readOutput(outDir, 'api/ex/FancyList.md');
        expect(content, contains(r'# FancyList\<Z\>'));
        expect(content, contains('extension FancyList<Z> on List<Z>'));
      });

      test('extension with static methods has Static Methods section', () {
        var content = _readOutput(outDir, 'api/ex/FancyList.md');
        expect(content, contains('## Static Methods'));
        expect(content, contains('### big()'));
      });

      test('extension with operators has Operators section', () {
        var content = _readOutput(outDir, 'api/ex/FancyList.md');
        expect(content, contains('## Operators'));
        expect(content, contains('### operator unary-()'));
      });

      // -- Generic function --------------------------------------------------

      test('generic function shows type parameter in heading and signature',
          () {
        var content = _readOutput(outDir, 'api/ex/genericFunction.md');
        expect(content, contains(r'# genericFunction\<T\>'));
        // Signature uses HTML with fn span: genericFunction&lt;T&gt;(T arg)
        expect(content,
            contains('<span class="fn">genericFunction&lt;T&gt;</span>('));
        expect(content, contains('member-signature'));
      });

      // -- Top-level getter --------------------------------------------------

      test('top-level getter page renders type', () {
        var content = _readOutput(outDir, 'api/ex/isCheck.md');
        expect(content, matches(RegExp(r'^# isCheck', multiLine: true)));
        expect(content, contains('isCheck'));
        expect(content, contains('member-signature'));
      });

      // -- Macro expansion in documentation ----------------------------------

      test('macro is expanded in documentation output', () {
        // isCheck getter has {@macro ex1} which should be expanded
        var content = _readOutput(outDir, 'api/ex/isCheck.md');
        expect(content, contains('ex2 macro content'));
      });

      // -- Deprecated top-level getter ---------------------------------------

      test('deprecated getter has badge and strikethrough', () {
        var content = _readOutput(outDir, 'api/ex/deprecatedGetter.md');
        expect(content, contains('~~deprecatedGetter~~'));
        expect(content, contains('<Badge type="warning" text="deprecated" />'));
        expect(content, contains(':::warning DEPRECATED'));
      });

      // -- Constant types ----------------------------------------------------

      test('constant page shows type in signature', () {
        var content = _readOutput(outDir, 'api/ex/COLOR.md');
        // Signature is now HTML: <span class="kw">const</span> String COLOR
        expect(content, contains('<span class="kw">const</span>'));
        expect(content, contains('COLOR'));
      });

      test('list constant shows parameterized type', () {
        var content = _readOutput(outDir, 'api/ex/PRETTY_COLORS.md');
        // Signature is HTML with &lt; &gt; for generics
        expect(content, contains('PRETTY_COLORS'));
        expect(content, contains('member-signature'));
      });

      // -- Admonition blocks in library docs ---------------------------------

      test('library documentation converts admonition blocks to VitePress containers', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        expect(content, contains(':::info'));
        expect(content, contains(':::tip'));
        expect(content, contains(':::warning'));
        expect(content, contains(':::danger'));
      });

      // -- Library overview table structure -----------------------------------

      test('library overview has table with Class and Description columns', () {
        var content = _readOutput(outDir, 'api/ex/index.md');
        expect(content, contains('| Class | Description |'));
      });

      // -- Scaffold file content ---------------------------------------------

      test('package.json has package name and vitepress dependency', () {
        var content = _readOutput(outDir, 'package.json');
        expect(content, contains('"test_package-docs"'));
        expect(content, contains('"vitepress"'));
      });

      test('config.ts imports sidebar modules and defines config', () {
        var content = _readOutput(outDir, '.vitepress/config.ts');
        expect(content, contains('defineConfig'));
        expect(content, contains('apiSidebar'));
        expect(content, contains('guideSidebar'));
      });

      test('config.ts has socialLinks from repository URL', () {
        var content = _readOutput(outDir, '.vitepress/config.ts');
        expect(content, contains('socialLinks'));
      });

      test('root index.md has hero layout with package name', () {
        var content = _readOutput(outDir, 'index.md');
        expect(content, contains('layout: home'));
        expect(content, contains('name: "test_package"'));
        expect(content, contains('API Documentation'));
      });

      // -- Overridden method -------------------------------------------------

      test('overridden method shows own documentation', () {
        var content =
            _readOutput(outDir, 'api/override_class/BoxConstraints.md');
        expect(content, contains('### debugAssertIsValid()'));
        expect(content, contains('Overrides the method in the superclass'));
      });

      test('const constructor in subclass shows const keyword', () {
        var content =
            _readOutput(outDir, 'api/override_class/BoxConstraints.md');
        // const keyword is now in a <span class="kw">const</span>
        expect(content, contains('<span class="kw">const</span>'));
        expect(content, contains('BoxConstraints()'));
      });

      // -- Heading anchor IDs -----------------------------------------------

      test('section headings have anchor IDs', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('{#section-constructors}'));
        expect(content, contains('{#section-properties}'));
        expect(content, contains('{#section-methods}'));
        expect(content, contains('{#section-operators}'));
      });

      test('member headings have anchor IDs', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        // Named constructor anchor (may have badges before {#...})
        expect(content, contains('{#fromstring}'));
        expect(content, contains('Apple.fromString()'));
        // Method anchor
        expect(content, contains('{#m1}'));
        expect(content, contains('m1()'));
      });

      // -- Extends clause in declaration -------------------------------------

      test('class extending generic base shows full type', () {
        var content = _readOutput(outDir, 'api/fake/SpecialList.md');
        expect(content, contains('class SpecialList<E> extends ListBase<E>'));
      });

      test('class extending concrete base shows extends', () {
        var content = _readOutput(outDir, 'api/fake/ExtraSpecialList.md');
        expect(
            content, contains('class ExtraSpecialList<E> extends SpecialList'));
      });

      // -- Operator reference in documentation --------------------------------

      test('operator reference in docs resolves to anchor link', () {
        var content = _readOutput(outDir, 'api/fake/OperatorReferenceClass.md');
        expect(content, contains('[OperatorReferenceClass.==]'));
      });

      // -- Mixed element library (fake has ALL types) -------------------------

      test('library with all element types has all section categories', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        expect(content, contains('## Classes'));
        expect(content, contains('## Enums'));
        expect(content, contains('## Mixins'));
        expect(content, contains('## Extensions'));
        expect(content, contains('## Functions'));
        expect(content, contains('## Properties'));
        expect(content, contains('## Typedefs'));
      });

      // -- Frontmatter description varies by page type -----------------------

      test('class page description mentions class', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('description: "API documentation for Apple'));
      });

      test('constant page description mentions constant', () {
        var content = _readOutput(outDir, 'api/ex/COLOR.md');
        expect(
            content, contains('description: "API documentation for the COLOR'));
      });

      test('property page description mentions property', () {
        var content = _readOutput(outDir, 'api/ex/isCheck.md');
        expect(content,
            contains('description: "API documentation for the isCheck'));
      });

      // -- Frontmatter outline differs by page type --------------------------

      test('class page outline includes nested levels', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('outline: [2, 3]'));
      });

      test('constant page outline is false', () {
        var content = _readOutput(outDir, 'api/ex/COLOR.md');
        expect(content, contains('outline: false'));
      });

      // -- InheritingClassOne extends private class --------------------------

      test('class extending private base shows private name in declaration',
          () {
        var content = _readOutput(outDir, 'api/fake/InheritingClassOne.md');
        expect(
            content,
            contains(
                'class InheritingClassOne extends _PrivateClassDefiningSomething'));
      });

      // -- Multiple libraries in sidebar -------------------------------------

      test('sidebar has entries for many libraries', () {
        var content =
            _readOutput(outDir, '.vitepress/generated/api-sidebar.ts');
        // Should have entries for several libraries
        expect(content, contains("'/api/ex/'"));
        expect(content, contains("'/api/fake/'"));
        expect(content, contains("'/api/override_class/'"));
      });

      // -- Implementers section (P0-4) --------------------------------------

      test('abstract class page has Implementers section', () {
        // Cat is abstract with implementers ConstantCat and Dog
        var content = _readOutput(outDir, 'api/ex/Cat.md');
        expect(content, contains(':::info Implementers'));
        expect(content, contains('ConstantCat'));
        expect(content, contains('Dog'));
      });

      // -- Available Extensions container (:::info) --------------------------

      test('class with extensions has info container for extensions', () {
        // Apple has AppleExtension — should have :::info Available Extensions
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains(':::info Available Extensions'));
      });

      // -- Source link (P0-5) ------------------------------------------------

      test('class page has View source link', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('[View source]('));
      });

      test('function page has View source link', () {
        var content = _readOutput(outDir, 'api/ex/testMacro.md');
        expect(content, contains('[View source]('));
      });

      // -- Enum value anchor prefix (P2-11) ----------------------------------

      test('enum value anchors have value- prefix', () {
        var content = _readOutput(outDir, 'api/fake/MacrosFromAccessors.md');
        // Enum values should have value- prefix
        expect(content, contains('{#value-'));
      });

      // -- Annotations section (P1-8) ----------------------------------------

      test('class with annotations shows Annotations section', () {
        // LongFirstLine has @Annotation('value')
        var content = _readOutput(outDir, 'api/fake/LongFirstLine.md');
        expect(content, contains('**Annotations:**'));
      });

      // -- Clickable type links in signatures --------------------------------

      test('member signature uses HTML div with pre/code', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('class="member-signature"'));
        expect(content, contains('<pre><code>'));
      });

      test('constructor signature has kw spans for keywords', () {
        // Apple.fromString is factory
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('<span class="kw">factory</span>'));
      });

      test('const constructor has kw span for const', () {
        var content = _readOutput(outDir, 'api/fake/ConstantClass.md');
        expect(content, contains('<span class="kw">const</span>'));
      });

      test('method return type uses type-link for local types', () {
        // Dog has getClassA() which returns List<Apple>
        // Apple is a local type, so it should be a type-link
        var content = _readOutput(outDir, 'api/ex/Dog.md');
        expect(content, contains('class="type-link"'));
        // Apple should be linked
        expect(content, contains('>Apple</a>'));
      });

      test('generic method return type uses HTML entities for angle brackets',
          () {
        // HasGenerics has convertToMap() returning Map<X, Y>?
        var content = _readOutput(outDir, 'api/fake/HasGenerics.md');
        // Angle brackets should be &lt; and &gt; in HTML
        expect(content, contains('&lt;'));
        expect(content, contains('&gt;'));
      });

      test('constructor taking local type has type-link', () {
        // LongFirstLine.fromHasGenerics(HasGenerics hg)
        var content = _readOutput(outDir, 'api/fake/LongFirstLine.md');
        expect(content, contains('fromHasGenerics('));
        // HasGenerics should be linked
        expect(content, contains('>HasGenerics</a>'));
      });

      test('external SDK types are NOT linked (no type-link class)', () {
        // Apple constructor takes String — SDK type, should be plain text
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        // String in Apple.fromString(String s) should NOT be a link
        expect(content, isNot(contains('>String</a>')));
        // But should be wrapped in a type span
        expect(content, contains('<span class="type">String</span>'));
      });

      test('void return type is plain text (not linked)', () {
        // Methods returning void should have plain "void" text
        var content = _readOutput(outDir, 'api/fake/SpecialList.md');
        // operator []= returns void — should NOT be a link
        expect(content, isNot(contains('>void</a>')));
        // But should be wrapped in a type span
        expect(content, contains('<span class="type">void</span>'));
      });

      test('nullable type has ? suffix after the type', () {
        // HasGenerics.convertToMap returns Map<X, Y>? — ? after &gt;
        var content = _readOutput(outDir, 'api/fake/HasGenerics.md');
        expect(content, contains('?'));
      });

      test('operator signature has return type linked', () {
        // LongFirstLine operator + returns LongFirstLine?
        var content = _readOutput(outDir, 'api/fake/LongFirstLine.md');
        expect(content, contains('operator +'));
      });

      test('container declaration still uses dart code block', () {
        // The class/enum/mixin declaration should remain in ```dart
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('```dart'));
        expect(content, contains('class Apple'));
      });

      test('field property signature uses member-signature', () {
        var content = _readOutput(outDir, 'api/fake/ImplicitProperties.md');
        expect(content, contains('class="member-signature"'));
      });

      test('field with getter shows get keyword in kw span', () {
        var content = _readOutput(outDir, 'api/fake/ImplicitProperties.md');
        expect(content, contains('<span class="kw">get</span>'));
      });

      test('final field shows final keyword in kw span', () {
        var content = _readOutput(outDir, 'api/ex/Dog.md');
        // Dog has aFinalField
        expect(content, contains('<span class="kw">final</span>'));
      });

      test('top-level function signature uses member-signature HTML', () {
        var content = _readOutput(outDir, 'api/fake/topLevelFunction.md');
        expect(content, contains('class="member-signature"'));
        // Should NOT have ```dart for the function signature
        var sigArea = content.split('## ')[0]; // Before any sections
        expect(sigArea, contains('<div class="member-signature">'));
      });

      test('top-level constant signature has const kw span', () {
        var content = _readOutput(outDir, 'api/ex/COLOR.md');
        expect(content, contains('<span class="kw">const</span>'));
      });

      test('generic class extends shows base type in declaration', () {
        // SpecialList<E> extends ListBase<E> — declaration in ```dart
        var content = _readOutput(outDir, 'api/fake/SpecialList.md');
        // Declaration stays in code block
        expect(content, contains('```dart'));
        expect(content, contains('class SpecialList<E> extends ListBase<E>'));
      });

      test('typedef signature uses member-signature with type-link', () {
        var content = _readOutput(outDir, 'api/fake/VoidCallback.md');
        expect(content, contains('class="member-signature"'));
        expect(content, contains('<span class="kw">typedef</span>'));
      });

      // -- Syntax highlighting spans in signatures ----------------------------

      test('method name uses fn span', () {
        var content = _readOutput(outDir, 'api/ex/Dog.md');
        // Dog has methods — their names should be wrapped in fn span
        expect(content, contains('class="fn"'));
      });

      test('constructor name uses fn span', () {
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        // Apple constructors should have fn spans
        expect(content, contains('<span class="fn">'));
      });

      test('parameter names use param span', () {
        // Apple.fromString(String s) — s is a parameter
        var content = _readOutput(outDir, 'api/ex/Apple.md');
        expect(content, contains('<span class="param">'));
      });

      test('field name uses fn span', () {
        var content = _readOutput(outDir, 'api/ex/Dog.md');
        // Dog has fields — their names should be fn spans
        expect(content, contains('<span class="fn">'));
      });

      test('typedef name uses fn span', () {
        var content = _readOutput(outDir, 'api/fake/VoidCallback.md');
        expect(content, contains('<span class="fn">VoidCallback</span>'));
      });

      test('top-level property name uses fn span', () {
        var content = _readOutput(outDir, 'api/ex/COLOR.md');
        expect(content, contains('<span class="fn">'));
      });

      // -- Generic escaping in markdown links (P2-10) ------------------------

      test('generic class name is escaped in library overview table', () {
        var content = _readOutput(outDir, 'api/fake/index.md');
        // HasGenerics<X, Y, Z> should have escaped angle brackets in links
        expect(content, contains(r'HasGenerics\<X, Y, Z\>'));
      });
    });

    // -----------------------------------------------------------------------
    // Group 2: Guide generation (test_package_with_docs)
    // -----------------------------------------------------------------------
    group('guide generation with test_package_with_docs', () {
      late final Folder outDir;

      setUpAll(() async {
        outDir = _resourceProvider.createSystemTemp('vitepress_guide.');
        var dartdoc =
            _buildVitePressDartdoc([], _testPackageWithDocsDir, outDir);
        await dartdoc.generateDocs();
      });

      tearDownAll(() {
        outDir.delete();
      });

      test('guide file is copied from doc/', () {
        expect(_outputExists(outDir, 'guide/getting-started.md'), isTrue);
        var content = _readOutput(outDir, 'guide/getting-started.md');
        expect(content, contains('# Getting Started'));
      });

      test('nested guide directory structure is preserved', () {
        expect(
            _outputExists(outDir, 'guide/advanced/configuration.md'), isTrue);
        var content = _readOutput(outDir, 'guide/advanced/configuration.md');
        expect(content, contains('# Configuration'));
      });

      test('guide-sidebar.ts contains guide entries', () {
        var content =
            _readOutput(outDir, '.vitepress/generated/guide-sidebar.ts');
        expect(content, contains('Getting Started'));
        expect(content, contains('Configuration'));
      });

      test('sidebar links do not contain .md extension', () {
        var content =
            _readOutput(outDir, '.vitepress/generated/guide-sidebar.ts');
        expect(content, isNot(contains("link: '/guide/getting-started.md'")));
      });
    });

    // -----------------------------------------------------------------------
    // Group 3: Dart 3 features (test_package_experiments)
    // -----------------------------------------------------------------------
    group('Dart 3 features (test_package_experiments)', () {
      late final Folder outDir;

      setUpAll(() async {
        outDir = _resourceProvider.createSystemTemp('vitepress_experiments.');
        runPubGet(_testPackageExperimentsDir.path);
        var dartdoc =
            _buildVitePressDartdoc([], _testPackageExperimentsDir, outDir);
        await dartdoc.generateDocs();
      });

      tearDownAll(() {
        outDir.delete();
      });

      // -- Class modifiers ---------------------------------------------------

      test('base class shows base modifier', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/B.md');
        expect(content, contains('base class'));
      });

      test('interface class shows interface modifier', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/C.md');
        expect(content, contains('interface class'));
      });

      test('final class shows final modifier', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/D.md');
        expect(content, contains('final class'));
      });

      test('sealed class shows sealed modifier', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/E.md');
        expect(content, contains('sealed class'));
      });

      test('abstract base class shows combined modifiers', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/G.md');
        expect(content, contains('abstract'));
        expect(content, contains('base class'));
      });

      test('abstract interface class shows combined modifiers', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/H.md');
        expect(content, contains('abstract'));
        expect(content, contains('interface class'));
      });

      test('abstract final class shows combined modifiers', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/I.md');
        expect(content, contains('abstract'));
        expect(content, contains('final class'));
      });

      test('mixin class shows mixin class modifier', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/J.md');
        expect(content, contains('mixin class'));
      });

      test('base mixin shows base mixin modifier', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/O.md');
        expect(content, contains('base mixin'));
      });

      // -- Modifier badges in headings -----------------------------------------

      test('sealed class has sealed badge in heading', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/E.md');
        expect(content, contains('<Badge type="info" text="sealed" />'));
      });

      test('base class has base badge in heading', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/B.md');
        expect(content, contains('<Badge type="info" text="base" />'));
      });

      test('interface class has interface badge in heading', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/C.md');
        expect(content, contains('<Badge type="info" text="interface" />'));
      });

      test('final class has final badge in heading', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/D.md');
        expect(content, contains('<Badge type="info" text="final" />'));
      });

      test('sealed class does NOT show abstract badge', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/E.md');
        expect(
            content, isNot(contains('<Badge type="info" text="abstract" />')));
      });

      test('base mixin has base badge in heading', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/O.md');
        expect(content, contains('<Badge type="info" text="base" />'));
      });

      test('mixin class has mixin badge in heading', () {
        var content = _readOutput(outDir, 'api/class_modifiers.dart/J.md');
        expect(content, contains('<Badge type="info" text="mixin" />'));
      });

      // -- Record types ------------------------------------------------------

      test('record typedef page exists', () {
        expect(_outputExists(outDir, 'api/records/RecordTypedef.md'), isTrue);
        var content = _readOutput(outDir, 'api/records/RecordTypedef.md');
        expect(content, contains('RecordTypedef'));
      });

      test('record variable page exists', () {
        expect(_outputExists(outDir, 'api/records/recordVariable.md'), isTrue);
      });

      test('function returning record type exists', () {
        expect(_outputExists(outDir, 'api/records/foo.md'), isTrue);
        var content = _readOutput(outDir, 'api/records/foo.md');
        expect(content, contains('member-signature'));
        expect(content, contains('foo'));
      });

      test('library overview lists record elements', () {
        var content = _readOutput(outDir, 'api/records/index.md');
        expect(content, contains('## Typedefs'));
        expect(content, contains('RecordTypedef'));
      });
    });

    // -----------------------------------------------------------------------
    // Group 4 (was 3): Incremental generation
    // -----------------------------------------------------------------------
    group('incremental generation', () {
      test('second run writes fewer files', () async {
        var outDir =
            _resourceProvider.createSystemTemp('vitepress_incremental.');
        try {
          var dartdoc1 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc1.generateDocs();
          var firstRunWritten = dartdoc1.generator.writtenFiles.length;

          var dartdoc2 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc2.generateDocs();
          var secondRunWritten = dartdoc2.generator.writtenFiles.length;

          expect(secondRunWritten, lessThan(firstRunWritten),
              reason: 'Second run should write fewer files than first run '
                  '(first=$firstRunWritten, second=$secondRunWritten)');
        } finally {
          outDir.delete();
        }
      });
    });

    // -----------------------------------------------------------------------
    // Group 4: Stale file deletion
    // -----------------------------------------------------------------------
    group('stale file deletion', () {
      test('stale .md file in api/ is deleted', () async {
        var outDir = _resourceProvider.createSystemTemp('vitepress_stale.');
        try {
          var dartdoc1 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc1.generateDocs();

          var staleFile = _resourceProvider
              .getFile(p.join(outDir.path, 'api', 'ex', 'StaleClass.md'));
          staleFile.writeAsStringSync('# StaleClass\nThis is stale.');
          expect(staleFile.exists, isTrue);

          var dartdoc2 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc2.generateDocs();

          expect(staleFile.exists, isFalse,
              reason: 'Stale .md file should be deleted');
        } finally {
          outDir.delete();
        }
      });

      test('stale .ts file in .vitepress/generated/ is deleted', () async {
        var outDir = _resourceProvider.createSystemTemp('vitepress_stale_ts.');
        try {
          var dartdoc1 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc1.generateDocs();

          var staleTs = _resourceProvider.getFile(
              p.join(outDir.path, '.vitepress', 'generated', 'old-sidebar.ts'));
          staleTs.writeAsStringSync('export const old = {};');
          expect(staleTs.exists, isTrue);

          var dartdoc2 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc2.generateDocs();

          expect(staleTs.exists, isFalse,
              reason: 'Stale .ts file should be deleted');
        } finally {
          outDir.delete();
        }
      });

      test('stale .md file in guide/ is deleted', () async {
        var outDir =
            _resourceProvider.createSystemTemp('vitepress_stale_guide.');
        try {
          var dartdoc1 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc1.generateDocs();

          var staleGuide = _resourceProvider
              .getFile(p.join(outDir.path, 'guide', 'old-guide.md'));
          staleGuide.writeAsStringSync('# Old Guide\nThis is stale.');
          expect(staleGuide.exists, isTrue);

          var dartdoc2 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc2.generateDocs();

          expect(staleGuide.exists, isFalse,
              reason: 'Stale .md file in guide/ should be deleted');
        } finally {
          outDir.delete();
        }
      });

      test('user files outside api/ are NOT deleted', () async {
        var outDir =
            _resourceProvider.createSystemTemp('vitepress_user_files.');
        try {
          var dartdoc1 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc1.generateDocs();

          var customFile =
              _resourceProvider.getFile(p.join(outDir.path, 'custom-page.md'));
          customFile.writeAsStringSync('# My Custom Page');

          var dartdoc2 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc2.generateDocs();

          expect(customFile.exists, isTrue,
              reason: 'User files outside api/ should not be deleted');
        } finally {
          outDir.delete();
        }
      });
    });

    // -----------------------------------------------------------------------
    // Group 5: Scaffold preservation (mutating, separate generation)
    // -----------------------------------------------------------------------
    group('scaffold preservation', () {
      test('scaffold files are not overwritten on second run', () async {
        var outDir = _resourceProvider.createSystemTemp('vitepress_scaffold.');
        try {
          var dartdoc1 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc1.generateDocs();

          // Modify config.ts to simulate user customization.
          var configFile = _resourceProvider
              .getFile(p.join(outDir.path, '.vitepress', 'config.ts'));
          var originalContent = configFile.readAsStringSync();
          configFile
              .writeAsStringSync('$originalContent\n// user customization');

          // Run generation again.
          var dartdoc2 = _buildVitePressDartdoc([], _testPackageDir, outDir);
          await dartdoc2.generateDocs();

          var afterContent = configFile.readAsStringSync();
          expect(afterContent, contains('// user customization'),
              reason: 'Scaffold files should not be overwritten');
        } finally {
          outDir.delete();
        }
      });
    });
  }, timeout: Timeout.factor(12));
}
