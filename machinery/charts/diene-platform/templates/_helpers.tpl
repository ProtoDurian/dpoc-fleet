{{/* steps: platform.yaml stages -> [[{landscape,gate,soak}]] ; unknown landscapes dropped */}}
{{- define "dp.steps" -}}
{{- $regions := .Values.regions | default dict -}}
{{- $out := list -}}
{{- range $s := .Values.stages -}}
  {{- $members := ternary $s (list $s) (kindIs "slice" $s) -}}
  {{- $step := list -}}
  {{- range $m := $members -}}
    {{- $o := ternary (dict "landscape" $m) $m (kindIs "string" $m) -}}
    {{- if hasKey $regions $o.landscape -}}
      {{- $step = append $step (dict "landscape" $o.landscape "gate" ($o.gate | default "auto") "soak" ($o.soak | default "")) -}}
    {{- end -}}
  {{- end -}}
  {{- if $step }}{{ $out = append $out $step }}{{ end -}}
{{- end -}}
{{- toJson (dict "steps" $out) -}}
{{- end -}}

{{- define "dp.unknown" -}}
{{- $regions := .Values.regions | default dict -}}
{{- $u := list -}}
{{- range $l := .Values.landscapes }}{{ if not (hasKey $regions $l) }}{{ $u = append $u $l }}{{ end }}{{ end -}}
{{- toJson $u -}}
{{- end -}}

{{/* one service's Kargo Warehouse + Stages. args: dict root svc */}}
{{- define "dp.pipeline" -}}
{{- $root := .root -}}{{- $p := $root.Values.platform -}}{{- $svc := .svc -}}{{- $np := $root.Values.namePrefix -}}
{{- $steps := (include "dp.steps" $root | fromJson).steps -}}
{{- $chart := printf "%s/%s%s-%s" $root.Values.oci.kargoCharts $np $p $svc -}}
{{- $pchart := printf "%s/%s%s-%s-primordial" $root.Values.oci.kargoCharts $np $p $svc -}}
{{- $image := printf "%s/%s%s-%s" $root.Values.oci.images $np $p $svc }}
{{- $carbon := eq $svc "carbon" }}
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Warehouse
metadata:
  name: {{ $svc }}
  namespace: {{ $p }}
  labels: {diene.atomi.cloud/service: {{ $svc }}}
spec:
  interval: 20s
  # one release = one semver for image + both charts; a half-published release makes no Freight
  freightCreationCriteria:
    expression: >-
      chartFrom('{{ $chart }}').Version == chartFrom('{{ $pchart }}').Version{{ if not $carbon }} &&
      chartFrom('{{ $chart }}').Version == imageFrom('{{ $image }}').Tag{{ end }}
  subscriptions:
    - chart: {repoURL: {{ $chart }}, semverConstraint: ">=1.0.0", discoveryLimit: 5}
    - chart: {repoURL: {{ $pchart }}, semverConstraint: ">=1.0.0", discoveryLimit: 5}
    {{- if not $carbon }}
    - image: {repoURL: {{ $image }}, imageSelectionStrategy: SemVer, constraint: ">=1.0.0", discoveryLimit: 5}
    {{- end }}
{{- range $i, $step := $steps }}
{{- range $m := $step }}
---
apiVersion: kargo.akuity.io/v1alpha1
kind: Stage
metadata:
  name: {{ $svc }}-{{ $m.landscape }}
  namespace: {{ $p }}
  labels:
    diene.atomi.cloud/service: {{ $svc }}
    diene.atomi.cloud/landscape: {{ $m.landscape }}
    diene.atomi.cloud/gate: {{ $m.gate }}
spec:
  requestedFreight:
    - origin: {kind: Warehouse, name: {{ $svc }}}
      sources:
      {{- if eq $i 0 }}
        direct: true
      {{- else }}
        {{- $prev := index $steps (sub $i 1) }}
        stages: [{{ range $j, $u := $prev }}{{ if $j }}, {{ end }}{{ $svc }}-{{ $u.landscape }}{{ end }}]
        {{- if gt (len $prev) 1 }}
        availabilityStrategy: All
        {{- end }}
        {{- if $m.soak }}
        requiredSoakTime: {{ $m.soak }}
        {{- end }}
      {{- end }}
  promotionTemplate:
    spec:
      vars:
        - {name: chart, value: "{{ $chart }}"}
        - {name: pchart, value: "{{ $pchart }}"}
        - {name: image, value: "{{ $image }}"}
        - {name: row, value: "./state/platforms/{{ $p }}/{{ $svc }}/{{ $m.landscape }}.yaml"}
      steps:
        - uses: git-clone
          config:
            repoURL: {{ $root.Values.state.pushURL }}
            checkout: [{branch: {{ $root.Values.state.branch }}, path: ./state}]
        - uses: yaml-update
          config:
            path: ${{ "{{" }} vars.row {{ "}}" }}
            updates:
              - {key: pin.primordial, value: "${{ "{{" }} chartFrom(vars.pchart).Version {{ "}}" }}"}
              - {key: pin.chart, value: "${{ "{{" }} chartFrom(vars.chart).Version {{ "}}" }}"}
              - {key: pin.image, value: "{{ if $carbon }}none{{ else }}${{ "{{" }} imageFrom(vars.image).Tag {{ "}}" }}{{ end }}"}
        - uses: git-commit
          config:
            path: ./state
            message: "promote {{ $p }}.{{ $svc }} ${{ "{{" }} chartFrom(vars.chart).Version {{ "}}" }} to {{ $m.landscape }}"
        - uses: git-push
          config: {path: ./state}
        # health gate: every Application of this row (primordial + every cluster) must be Healthy at the new version.
        # Primordial health = the dependency records are Ready (custom health in argocd-cm) = secrets written (G3).
        - uses: argocd-update
          retry: {errorThreshold: 40, timeout: 15m}
          config:
            apps:
              - selector:
                  matchLabels: {diene.atomi.cloud/platform: {{ $p }}, diene.atomi.cloud/service: {{ $svc }}, diene.atomi.cloud/landscape: {{ $m.landscape }}, diene.atomi.cloud/kind: primordial}
                sources:
                  - repoURL: {{ $root.Values.oci.argoRepo }}
                    chart: {{ $np }}{{ $p }}-{{ $svc }}-primordial
                    desiredRevision: "${{ "{{" }} chartFrom(vars.pchart).Version {{ "}}" }}"
                    updateTargetRevision: false
              - selector:
                  matchLabels: {diene.atomi.cloud/platform: {{ $p }}, diene.atomi.cloud/service: {{ $svc }}, diene.atomi.cloud/landscape: {{ $m.landscape }}, diene.atomi.cloud/kind: app}
                sources:
                  - repoURL: {{ $root.Values.oci.argoRepo }}
                    chart: {{ $np }}{{ $p }}-{{ $svc }}
                    desiredRevision: "${{ "{{" }} chartFrom(vars.chart).Version {{ "}}" }}"
                    updateTargetRevision: false
{{- end }}
{{- end }}
{{- end -}}
