from pathlib import Path
import html
root=Path(__file__).parent
objects=[]
count=0
def add(body):
 global count
 count+=1; key=f'{count:024X}';objects.append(f'{key} = {{{body}}};');return key
def group(folder):
 refs=[];builds=[]
 for p in sorted((root/folder).rglob('*.swift')):
  ref=add(f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = "{p.relative_to(root/folder)}"; sourceTree = "<group>";')
  refs.append(ref);builds.append(add(f'isa = PBXBuildFile; fileRef = {ref};'))
 g=add(f'isa = PBXGroup; path = "{folder}"; sourceTree = "<group>"; children = ({",".join(refs)});')
 return g,builds
groups=[];targets=[];products=[]
base='SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; CLANG_ENABLE_OBJC_ARC = YES; '
def configs(extra):
 ids=[]
 for name in ['Debug','Release']:
  mode='SWIFT_OPTIMIZATION_LEVEL = "-Onone"; ENABLE_TESTABILITY = YES; SWIFT_ACTIVE_COMPILATION_CONDITIONS = DEBUG;' if name=='Debug' else 'SWIFT_COMPILATION_MODE = wholemodule;'
  ids.append(add(f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{{base}{extra}{mode}}};'))
 return add(f'isa = XCConfigurationList; buildConfigurations = ({",".join(ids)}); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
projectconfig=configs('')
app=None
for name,folder,kind in [('SellPilot','SellPilot','application'),('SellPilotTests','SellPilotTests','bundle.unit-test'),('SellPilotUITests','SellPilotUITests','bundle.ui-testing')]:
 g,builds=group(folder);groups.append(g)
 ext='app' if kind=='application' else 'xctest'
 product=add(f'isa = PBXFileReference; explicitFileType = {"wrapper.application" if ext=="app" else "wrapper.cfbundle"}; path = {name}.{ext}; sourceTree = BUILT_PRODUCTS_DIR;');products.append(product)
 settings=f'PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = com.sellpilot.{name.lower()}; GENERATE_INFOPLIST_FILE = YES; TARGETED_DEVICE_FAMILY = "1,2"; CODE_SIGN_STYLE = Automatic; MARKETING_VERSION = 0.1; CURRENT_PROJECT_VERSION = 1; '
 if kind=='application':
  settings+='INFOPLIST_KEY_CFBundleDisplayName = SellPilot; INFOPLIST_KEY_UILaunchScreen_Generation = YES; INFOPLIST_KEY_UIApplicationSceneManifest_Generation = YES; INFOPLIST_KEY_NSCameraUsageDescription = "Take photos of items you want to sell."; INFOPLIST_KEY_NSMicrophoneUsageDescription = "Dictate seller notes."; INFOPLIST_KEY_NSSpeechRecognitionUsageDescription = "Transcribe your dictated seller notes."; INFOPLIST_KEY_UISupportedInterfaceOrientations = "UIInterfaceOrientationPortrait UIInterfaceOrientationLandscapeLeft UIInterfaceOrientationLandscapeRight"; '
 elif kind=='bundle.unit-test': settings+='TEST_HOST = "$(BUILT_PRODUCTS_DIR)/SellPilot.app/SellPilot"; BUNDLE_LOADER = "$(TEST_HOST)"; '
 else: settings+='TEST_TARGET_NAME = SellPilot; '
 config=configs(settings)
 sources=add(f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(builds)}); runOnlyForDeploymentPostprocessing = 0;')
 frameworks=add('isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
 resources=add('isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
 dep=add(f'isa = PBXTargetDependency; target = {app};') if app else None
 target=add(f'isa = PBXNativeTarget; name = {name}; productName = {name}; productReference = {product}; productType = "com.apple.product-type.{kind}"; buildConfigurationList = {config}; buildPhases = ({sources},{frameworks},{resources}); dependencies = ({dep or ""});')
 if app is None: app=target
 targets.append((name,target))
pg=add(f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({",".join(products)});')
main=add(f'isa = PBXGroup; sourceTree = "<group>"; children = ({",".join(groups+[pg])});')
project=add(f'isa = PBXProject; buildConfigurationList = {projectconfig}; compatibilityVersion = "Xcode 15.0"; developmentRegion = en; knownRegions = (en,Base); mainGroup = {main}; productRefGroup = {pg}; projectDirPath = ""; projectRoot = ""; targets = ({",".join(t for n,t in targets)}); attributes = {{BuildIndependentTargetsInParallel = YES; LastUpgradeCheck = 2600;}};')
p=root/'SellPilot.xcodeproj';p.mkdir(exist_ok=True)
(p/'project.pbxproj').write_text('// !$*UTF8*$!\n{archiveVersion = 1; classes = {}; objectVersion = 60; objects = {\n'+'\n'.join(objects)+f'\n}}; rootObject = {project};}}\n')
s=p/'xcshareddata/xcschemes';s.mkdir(parents=True,exist_ok=True)
def reference(name,t):return f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{t}" BuildableName="{name}.{"app" if name=="SellPilot" else "xctest"}" BlueprintName="{name}" ReferencedContainer="container:SellPilot.xcodeproj"/>'
r=reference(*targets[0]); tests=''.join(f'<TestableReference skipped="NO">{reference(n,t)}</TestableReference>' for n,t in targets[1:])
(s/'SellPilot.xcscheme').write_text(f'''<?xml version="1.0" encoding="UTF-8"?><Scheme LastUpgradeVersion="2600" version="1.3"><BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{r}</BuildActionEntry></BuildActionEntries></BuildAction><TestAction buildConfiguration="Debug" shouldUseLaunchSchemeArgsEnv="YES"><Testables>{tests}</Testables></TestAction><LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugServiceExtension="internal" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{r}</BuildableProductRunnable></LaunchAction><ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES"><BuildableProductRunnable runnableDebuggingMode="0">{r}</BuildableProductRunnable></ProfileAction><AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/></Scheme>''')
