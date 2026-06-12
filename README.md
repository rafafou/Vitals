<p align="center">
  <img src="vitals-logo.svg" width="92" alt="Vitals logo">
</p>

<h1 align="center">Vitals</h1>
<p align="center"><strong>Health checks for your Roblox game.</strong><br>
Three plugins for Roblox Studio to ship a game that's <em>safe, stable &amp; light</em>.</p>

<p align="center">
  🌐 <a href="https://rafafou.github.io/Vitals/"><strong>rafafou.github.io/Vitals</strong></a>
</p>

---

## 🩺 Qu'est-ce que Vitals ?

Trois choses cassent les jeux Roblox : les **exploiters**, les **fuites mémoire**, et le
**surpoids** (chargement lent / lag). Pour aucune des trois il n'existait de bon outil
gratuit. **Vitals** comble ce vide avec trois plugins ciblés qui auditent ton jeu là où ça
compte et te disent exactement quoi corriger — chacun avec son **score** pour mesurer ta
progression.

| Plugin | Question | Ce qu'il fait | Fichier |
|--------|----------|---------------|---------|
| 🛡️ **Vitals · Security** | *Mon jeu est-il sûr ?* | Audite tes RemoteEvents, score /100, quick-fix en un clic | [`RemoteSecurityAuditor.luau`](RemoteSecurityAuditor.luau) |
| 🩺 **Vitals · Memory** | *Mon jeu est-il stable ?* | Repère les connexions qui fuient + graphe mémoire en live | [`MemoryLeakTracker.luau`](MemoryLeakTracker.luau) |
| ⚡ **Vitals · Performance** | *Mon jeu est-il léger ?* | Trouve code mort, CSG lourd, parts inutiles, score /100 | [`PlaceOptimizer.luau`](PlaceOptimizer.luau) |

Chaque plugin a son README détaillé :
[Security](README_Security.md) · [Memory](README_LeakTracker.md) · [Performance](README_PlaceOptimizer.md)

## ⬇️ Installation (2 min, identique pour chaque plugin)

1. Ouvre **Roblox Studio**.
2. Colle le contenu du `.luau` dans un `Script` temporaire.
3. Clic droit sur le script → **« Save as Local Plugin »**.
4. Le plugin apparaît dans l'onglet **Plugins**, barre d'outils **Vitals** (boutons
   *Security · Memory · Performance*).
5. Au premier scan, autorise la permission **« Injection de script »** (lecture seule du
   code — les plugins ne modifient jamais ton jeu sans ton clic).

## ⚠️ À savoir

Vitals fait de l'**analyse heuristique** : ce sont des **aides à la revue**, pas des
garanties formelles. Vérifie toujours une alerte (et le code inséré par un quick-fix) avant
d'agir. Faux positifs et faux négatifs sont possibles.

## 📄 Licence & marque

Non affilié à Roblox Corporation. « Roblox » est une marque de Roblox Corporation, utilisée
ici de façon purement descriptive.

---

<p align="center"><em>Vitals — safe · stable · light.</em></p>
