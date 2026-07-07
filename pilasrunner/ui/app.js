const games = [
  {
    title: "AM2R",
    kind: "APK",
    arch: "armhf",
    runtime: "gmloader-next.armhf",
    profile: "default profile",
    save: "ready",
    controls: "mapped",
    status: "ready",
    color: "#d8ff29"
  },
  {
    title: "Celeste Classic",
    kind: "Folder",
    arch: "aarch64",
    runtime: "gmloader-next.aarch64",
    profile: "custom profile",
    save: "ready",
    controls: "mapped",
    status: "ready",
    color: "#58e6ff"
  },
  {
    title: "Pizza Tower Demo",
    kind: "APK",
    arch: "aarch64",
    runtime: "gmloader-next.aarch64",
    profile: "needs profile",
    save: "new",
    controls: "review",
    status: "needs-profile",
    color: "#ffca5c"
  },
  {
    title: "Undertale Yellow",
    kind: "Folder",
    arch: "armhf",
    runtime: "gmloader-next.armhf",
    profile: "custom profile",
    save: "ready",
    controls: "mapped",
    status: "ready",
    color: "#34d337"
  }
];

const list = document.querySelector("#gameList");
const tabs = document.querySelectorAll(".tab");
const clock = document.querySelector("#clock");
const title = document.querySelector("#gameTitle");
const kind = document.querySelector("#gameKind");
const arch = document.querySelector("#arch");
const runtime = document.querySelector("#runtime");
const profile = document.querySelector("#profile");
const save = document.querySelector("#save");
const controls = document.querySelector("#controls");
const cover = document.querySelector("#coverArt");
const launchButton = document.querySelector("#launchButton");
const scanButton = document.querySelector("#scanButton");
const settingsButton = document.querySelector("#settingsButton");
const activityTitle = document.querySelector("#activityTitle");
const activityState = document.querySelector("#activityState");
const activityText = document.querySelector("#activityText");
const progressFill = document.querySelector("#progressFill");

let activeFilter = "all";
let selectedIndex = 0;
let visibleGames = [...games];
let progressTimer = null;

function updateClock() {
  const now = new Date();
  clock.textContent = now.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
}

function gameInitial(game) {
  return game.title.trim().slice(0, 1).toUpperCase();
}

function renderList() {
  visibleGames = games.filter((game) => activeFilter === "all" || game.status === activeFilter);

  if (selectedIndex >= visibleGames.length) {
    selectedIndex = Math.max(0, visibleGames.length - 1);
  }

  list.innerHTML = "";

  visibleGames.forEach((game, index) => {
    const row = document.createElement("button");
    row.type = "button";
    row.className = `game-row${index === selectedIndex ? " is-selected" : ""}`;
    row.dataset.index = index;
    row.innerHTML = `
      <span class="tile" style="background: linear-gradient(135deg, ${game.color}, #34d337)">${gameInitial(game)}</span>
      <span>
        <span class="row-title">${game.title}</span>
        <span class="row-meta">${game.runtime}</span>
      </span>
      <span class="badge">${game.arch}</span>
    `;
    row.addEventListener("click", () => {
      selectedIndex = index;
      renderList();
      renderDetails();
      setActivity("Ready", "idle", "Waiting for selection.", 0);
    });
    list.append(row);
  });

  renderDetails();
}

function renderDetails() {
  const game = visibleGames[selectedIndex] || games[0];

  title.textContent = game.title;
  kind.textContent = game.kind;
  arch.textContent = game.arch;
  runtime.textContent = game.runtime;
  profile.textContent = game.profile;
  save.textContent = game.save;
  controls.textContent = game.controls;
  cover.dataset.letter = gameInitial(game);
  cover.style.backgroundImage = `linear-gradient(135deg, ${game.color}33, rgba(4, 12, 7, 0.74)), url("../assets/logo.png")`;
}

function setActivity(head, state, text, progress) {
  activityTitle.textContent = head;
  activityState.textContent = state;
  activityText.textContent = text;
  progressFill.style.width = `${progress}%`;
}

function simulateLaunch() {
  const game = visibleGames[selectedIndex] || games[0];
  const steps = [
    ["Preparing", "scan", `Validating ${game.kind.toLowerCase()} package.`, 18],
    ["Configuring", "json", `Writing gmloader.json for ${game.arch}.`, 42],
    ["Mapping", "input", `Applying ${game.profile}.`, 66],
    ["Launching", "run", `Starting ${game.runtime}.`, 88],
    ["Running", "ok", `${game.title} is ready on the runner.`, 100]
  ];
  let step = 0;

  clearInterval(progressTimer);
  setActivity(...steps[0]);

  progressTimer = setInterval(() => {
    step += 1;
    if (step >= steps.length) {
      clearInterval(progressTimer);
      return;
    }
    setActivity(...steps[step]);
  }, 640);
}

function simulateScan() {
  clearInterval(progressTimer);
  setActivity("Scanning", "apk", "Refreshing the game library.", 35);
  setTimeout(() => setActivity("Updated", "ok", `${visibleGames.length} entries visible.`, 100), 620);
}

function openSettings() {
  const game = visibleGames[selectedIndex] || games[0];
  clearInterval(progressTimer);
  setActivity("Config", "profile", `${game.title}: ${game.profile}, controls ${game.controls}.`, 72);
}

tabs.forEach((tab) => {
  tab.addEventListener("click", () => {
    tabs.forEach((item) => item.classList.remove("is-active"));
    tab.classList.add("is-active");
    activeFilter = tab.dataset.filter;
    selectedIndex = 0;
    renderList();
    setActivity("Filtered", "list", `${visibleGames.length} entries visible.`, 100);
  });
});

document.addEventListener("keydown", (event) => {
  if (event.key === "ArrowDown") {
    selectedIndex = Math.min(selectedIndex + 1, visibleGames.length - 1);
    renderList();
  }
  if (event.key === "ArrowUp") {
    selectedIndex = Math.max(selectedIndex - 1, 0);
    renderList();
  }
  if (event.key === "Enter") {
    simulateLaunch();
  }
});

launchButton.addEventListener("click", simulateLaunch);
scanButton.addEventListener("click", simulateScan);
settingsButton.addEventListener("click", openSettings);

updateClock();
setInterval(updateClock, 30000);
renderList();
