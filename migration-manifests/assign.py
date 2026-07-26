#!/usr/bin/env python3
"""Assign every tracked file under ../qits (minus webui/target) to a migration target."""
import re, sys, collections

SRC = "/tmp/claude-1000/-home-wohlben-code-qits-qits/148e2d54-70ab-401c-92a6-a939008c68c5/scratchpad/all.txt"

# --- domain/repository is the one package that genuinely splits -------------
WS_REPO = {  # workspace-scoped -> qits-workspaces
 "control/AngularComponentParser","control/ComponentMapService","control/ContainerFileAccess",
 "control/ContainerRuntime","control/DetectionService","control/DockerExecutor",
 "control/FrameworkDetectionService","control/GitignoreLazyDirectoryStrategy",
 "control/LazyDirectoryStrategy","control/ProvisionResult","control/ProxyOrigin",
 "control/QitsConfig","control/QitsHostResolver","control/WorkingTreeMarker",
 "control/WorkspaceAgentActivity","control/WorkspaceBootstrapDriver","control/WorkspaceCheckpointService",
 "control/WorkspaceConfigReader","control/WorkspaceConfigView","control/WorkspaceContainer",
 "control/WorkspaceContainerEventPublisher","control/WorkspaceContainerFactory",
 "control/WorkspaceContainerStarted","control/WorkspaceContainerStopping",
 "control/WorkspaceDaemonInfo","control/WorkspaceDaemonLiveness","control/WorkspaceDaemonProvisioner",
 "control/WorkspaceFileAccess","control/WorkspaceFilesService","control/WorkspaceGitStatus",
 "control/WorkspaceGitSync","control/WorkspaceHistoryService","control/WorkspaceMetadata",
 "control/WorkspacePromptAttachmentService","control/WorkspacePromptDraftService",
 "control/WorkspaceReadyForServices","control/WorkspaceResolver","control/WorkspaceService",
 "control/WorkspaceServiceDriver","control/WorkspaceTreeFingerprint","control/GitExecutor",
 "control/GitIdentity",
 "entity/PromptAttachmentSource","entity/Workspace","entity/WorkspaceEvent","entity/WorkspaceEventType",
 "entity/WorkspacePromptAttachment","entity/WorkspacePromptDraft","entity/WorkspaceRuntimeStatus",
 "entity/WorkspaceStatus",
 "dto/ComponentMapDto","dto/ComponentMapEntryDto","dto/ComponentSelectorDto","dto/DetectedProjectDto",
 "dto/DetectionDto","dto/FileLinkDto","dto/FrameworkMembershipDto","dto/LazyDirDto","dto/TestLinkDto",
 "dto/WorkspaceDto","dto/WorkspaceEventDto","dto/WorkspaceFileContentDto","dto/WorkspaceHistoryDetailDto",
 "dto/WorkspaceHistoryDto","dto/WorkspacePromptAttachmentDataDto","dto/WorkspacePromptDraftDto",
 "mapper/WorkspaceMapper","mapper/WorkspacePromptDraftMapper",
 "persistence/WorkspaceEventRepository","persistence/WorkspacePromptAttachmentRepository",
 "persistence/WorkspacePromptDraftRepository","persistence/WorkspaceRepository",
}
PROJ_REPO = {  # repo-scoped -> qits-projects
 "control/CommitService","control/GitExecutor","control/GitIdentity","control/GitRemoteAuth",
 "control/GitSubmoduleParser","control/MetadataService","control/ProjectTemplate",
 "control/QitsConfigParser","control/RemoteLoginSession","control/RemoteLoginSessions",
 "control/RepositoryDiscoveryService","control/RepositoryMetadata","control/RepositoryNameResolver",
 "control/RepositoryService","control/ResolveConflictService","control/ContainerRuntime",
 "control/DockerExecutor","control/QitsConfig","control/QitsHostResolver",
 "entity/Repository","entity/RepositoryArchetype","entity/RepositoryName","entity/RepositorySubmodule",
 "dto/BranchDto","dto/CommitChangesDto","dto/CommitDto","dto/CommitFileChangeDto","dto/CommitFileDiffDto",
 "dto/CommitLogDto","dto/RepositoryDto","dto/RepositorySubmoduleDto","dto/SyncStatusDto",
 "mapper/RepositoryMapper","mapper/RepositorySubmoduleMapper",
 "persistence/RepositoryNameRepository","persistence/RepositoryRepository",
 "persistence/RepositorySubmoduleRepository",
}

MIG = {  # migration -> targets
 "V1":["projects"],"V2":["monolith"],"V3":["projects"],"V4":["monolith"],"V5":["monolith"],
 "V6":["monolith"],"V7":["monolith"],"V8":["daemon-commands"],"V9":["daemon-commands"],
 "V10":["projects","workspaces"],"V11":["monolith"],"V12":["daemon-commands"],
 "V13":["daemon-commands"],"V14":["workspaces"],"V15":["workspaces"],"V16":["workspaces"],
 "V17":["workspaces"],"V18":["daemon-commands"],"V19":["workspaces"],"V20":["projects"],
 "V21":["workspaces"],"V22":["workspaces"],"V23":["workspaces"],
 "V24":["projects","workspaces"],"V25":["workspaces"],"V26":["workspaces"],"V27":["monolith"],
 "V28":["daemon-commands","daemon-agents"],"V29":["daemon-commands"],"V30":["daemon-agents"],
 "V31":["workspaces"],"V32":["daemon-commands"],"V33":["projects"],"V34":["projects"],
 "V35":["workspaces"],"V36":["workspaces"],"V37":["workspaces"],"V38":["workspaces"],
 "V39":["daemon-agents"],"V40":["unassigned"],"V41":["projects"],"V42":["workspaces"],
 "V43":["monolith","workspaces","projects"],"V44":["projects"],"V45":["workspaces"],
}

def classify(p):
    """return (primary_target, note)"""
    # ---- whole maven modules --------------------------------------------
    if p.startswith("artifacts/"):   return "artifacts", "artifacts module"
    if p.startswith("epics/"):       return "projects",  "epics module"
    if p.startswith("ci/"):          return "ci",        "ci module"
    if p.startswith("auth/"):        return "unassigned","auth variants"
    if p.startswith("cli/"):         return "unassigned","cli seeding tool"
    if p.startswith("workspace-daemon-protocol/"): return "daemon-done","already extracted"
    if p.startswith("workspace-daemon/"):          return "daemon-done","already extracted"
    if p.startswith("qits-userflows/"):            return "userflows-done","already extracted"
    if p.startswith("userflows/"):                 return "monolith","product stories"

    # ---- domain module ---------------------------------------------------
    if p.startswith("domain/"):
        if "/db/migration/" in p:
            v = re.search(r"/(V\d+)__", p).group(1)
            t = MIG[v]
            return t[0], "flyway " + v + (" (also " + ",".join(t[1:]) + ")" if len(t) > 1 else "")
        if "/resources/project-template/" in p: return "projects", "project skeleton"
        if "/resources/speech/" in p:           return "stt", "python worker"
        if p.endswith("/pom.xml") or "/.settings/" in p or p.endswith(".project") \
           or p.endswith(".classpath"): return "monolith", "reactor build file"
        if "/src/test/resources/fixtures/submodule-" in p:
            return "projects", "submodule graph fixture"
        if re.search(r"/src/test/resources/fixtures/testing-repo", p):
            return "DUPLICATE", "fixture gitlink (submodule)"
        if "/src/test/resources/" in p:
            return "DUPLICATE", "test scaffolding"
        if "/qits/validation/ProjectSlug" in p:
            return "projects", "slug validator"
        if "/qits/validation/" in p:
            return "DUPLICATE", "shared bean-validation annotation"
        m = re.search(r"/qits/domain/([a-z]+)/", p)
        area = m.group(1) if m else None
        if area == "repository":
            if p.endswith("/repository/package-info.java"):
                return "projects", "polyrepo model doc"
            if p.endswith("/repository/AGENTS.md"):
                return "projects", "repo+workspace model doc"
            key = re.search(r"/repository/(.*?)(?:Test|IT)?\.java$", p)
            if key:
                k = key.group(1)
                if k in WS_REPO:   return "workspaces", "workspace half"
                if k in PROJ_REPO: return "projects", "repository half"
                # tests + fakes: name-driven
                leaf = k.rsplit("/", 1)[-1]
                if leaf.startswith("Fake") or leaf.startswith("Workspace") \
                   or leaf in ("GitIdentityAttribution","IncomingMergePullNotification",
                               "IntegrateSyncsSourceContainer"):
                    return "workspaces", "workspace test/fake"
                if leaf.startswith("Repository"):
                    return "projects", "repository test"
                return "REVIEW", "unclassified repository/" + k
            if p.endswith("package-info.java"): return "projects", "polyrepo model doc"
            return "projects", "repository non-java"
        if area in ("bootstrap","capture","process","service","workspace"):
            return "workspaces", "domain." + area
        if area == "agent":   return "daemon-agents", "domain.agent"
        if area == "command": return "daemon-commands", "domain.command"
        if area in ("project","seeding"): return "projects", "domain." + area
        if area == "speech":  return "stt", "domain.speech"
        if area == "featureflow": return "monolith", "out of scope"
        if area == "setting": return "unassigned", "domain.setting"
        if area == "error":   return "DUPLICATE", "copied per target"
        if area == "testsupport": return "DUPLICATE", "test scaffolding"
        return "REVIEW", "domain/? " + p

    # ---- service module --------------------------------------------------
    if p.startswith("service/"):
        if "/artifacts/api/" in p: return "artifacts", "REST boundary"
        if "/ci/api/" in p or "/ci/control/" in p: return "ci", "REST boundary"
        if "/epics/api/" in p:     return "projects", "REST boundary"
        if "/githost/" in p:       return "artifacts", "git smart-HTTP host"
        if "/domain/telemetry/" in p: return "observability", "telemetry"
        if "/domain/speech/" in p:    return "stt", "REST boundary"
        if "/domain/agent/" in p:     return "daemon-agents", "REST boundary"
        if "/domain/command/" in p or "/domain/chat/" in p:
            return "daemon-commands", "REST/WS boundary"
        if "/domain/repository/" in p: return "projects", "REST/MCP boundary"
        if "/domain/project/" in p:    return "projects", "REST boundary"
        if any(x in p for x in ("/domain/workspace/","/domain/bootstrap/","/domain/capture/",
                                "/domain/process/","/domain/service/","/serviceproxy/",
                                "/workspacedaemonhost/")):
            return "workspaces", "workspace boundary"
        if "/domain/featureflow/" in p: return "monolith", "out of scope"
        if "/domain/setting/" in p:     return "unassigned", "domain.setting"
        if "/seeding/" in p:            return "projects", "self-seed gate"
        if "/security/" in p:           return "unassigned", "auth variant test"
        return "monolith", "app shell"

    return "REVIEW", p

rows = [l.strip() for l in open(SRC) if l.strip()]
by = collections.defaultdict(list)
for p in rows:
    t, note = classify(p)
    by[t].append((p, note))

for t in sorted(by, key=lambda k: -len(by[k])):
    print(f"{len(by[t]):5d}  {t}")
print(f"{len(rows):5d}  TOTAL")
if by["REVIEW"]:
    print("\n!! UNCLASSIFIED:")
    for p, n in by["REVIEW"]: print("   ", p, "|", n)

# --- emit per-target manifests ---------------------------------------------
import os
os.makedirs("manifests", exist_ok=True)
for t, items in by.items():
    with open(f"manifests/{t}.txt", "w") as f:
        for p, n in sorted(items):
            f.write(f"{p}\t{n}\n")
