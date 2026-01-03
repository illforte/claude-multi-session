#!/usr/bin/env node
/**
 * Sprint History Tracker
 *
 * Tracks multi-session sprints for cost analysis and retrospectives.
 *
 * Usage:
 *   node scripts/lib/sprint-tracker.mjs add <json-data>    # Add new sprint
 *   node scripts/lib/sprint-tracker.mjs list [--limit N]   # List sprints
 *   node scripts/lib/sprint-tracker.mjs stats              # Show statistics
 *   node scripts/lib/sprint-tracker.mjs report [sprint-id] # Generate report
 *   node scripts/lib/sprint-tracker.mjs export [format]    # Export (md, csv)
 */

import { readFileSync, writeFileSync, existsSync } from 'fs';
import { join, dirname } from 'path';
import { fileURLToPath } from 'url';

const __dirname = dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = join(__dirname, '../..');
const HISTORY_FILE = join(PROJECT_ROOT, '.claude/sprint-history.json');

// Load sprint history
function loadHistory() {
  if (!existsSync(HISTORY_FILE)) {
    return {
      version: '1.0',
      description: 'Multi-session sprint history for cost tracking and retrospectives',
      sprints: [],
      cumulative: {
        total_sprints: 0,
        total_tasks: 0,
        total_cost_usd: 0,
        total_duration_seconds: 0,
        average_cost_per_sprint: 0,
        average_tasks_per_sprint: 0
      }
    };
  }
  return JSON.parse(readFileSync(HISTORY_FILE, 'utf8'));
}

// Save sprint history
function saveHistory(history) {
  writeFileSync(HISTORY_FILE, JSON.stringify(history, null, 2));
}

// Generate sprint ID
function generateSprintId() {
  const now = new Date();
  const date = now.toISOString().split('T')[0].replace(/-/g, '-');
  const history = loadHistory();
  const todayCount = history.sprints.filter(s => s.id.startsWith(`sprint-${date}`)).length + 1;
  return `sprint-${date}-${String(todayCount).padStart(3, '0')}`;
}

// Update cumulative stats
function updateCumulativeStats(history) {
  const sprints = history.sprints;
  if (sprints.length === 0) {
    history.cumulative = {
      total_sprints: 0,
      total_tasks: 0,
      total_cost_usd: 0,
      total_duration_seconds: 0,
      average_cost_per_sprint: 0,
      average_tasks_per_sprint: 0
    };
    return;
  }

  const totalTasks = sprints.reduce((sum, s) => sum + s.totals.tasks_completed, 0);
  const totalCost = sprints.reduce((sum, s) => sum + s.totals.cost_usd, 0);
  const totalDuration = sprints.reduce((sum, s) => sum + s.totals.duration_seconds, 0);

  history.cumulative = {
    total_sprints: sprints.length,
    total_tasks: totalTasks,
    total_cost_usd: Math.round(totalCost * 100) / 100,
    total_duration_seconds: totalDuration,
    average_cost_per_sprint: Math.round((totalCost / sprints.length) * 100) / 100,
    average_tasks_per_sprint: Math.round((totalTasks / sprints.length) * 10) / 10
  };
}

// Add a new sprint
function addSprint(sprintData) {
  const history = loadHistory();

  // Parse if string
  const sprint = typeof sprintData === 'string' ? JSON.parse(sprintData) : sprintData;

  // Generate ID if not provided
  if (!sprint.id) {
    sprint.id = generateSprintId();
  }

  // Add timestamp if not provided
  if (!sprint.date) {
    sprint.date = new Date().toISOString();
  }

  // Calculate totals if not provided
  if (!sprint.totals && sprint.tasks) {
    const completed = sprint.tasks.filter(t => t.status === 'completed').length;
    const failed = sprint.tasks.filter(t => t.status === 'failed').length;
    const totalCost = sprint.tasks.reduce((sum, t) => sum + (t.cost_usd || 0), 0);
    const maxDuration = Math.max(...sprint.tasks.map(t => t.duration_seconds || 0));

    sprint.totals = {
      tasks_completed: completed,
      tasks_failed: failed,
      duration_seconds: maxDuration,
      cost_usd: Math.round(totalCost * 100) / 100
    };
  }

  history.sprints.push(sprint);
  updateCumulativeStats(history);
  saveHistory(history);

  console.log(`✅ Sprint ${sprint.id} recorded`);
  console.log(`   Tasks: ${sprint.totals.tasks_completed} completed, ${sprint.totals.tasks_failed} failed`);
  console.log(`   Cost: $${sprint.totals.cost_usd}`);
  console.log(`   Duration: ${Math.round(sprint.totals.duration_seconds / 60)}m`);

  return sprint;
}

// List sprints
function listSprints(limit = 10) {
  const history = loadHistory();
  const sprints = history.sprints.slice(-limit).reverse();

  if (sprints.length === 0) {
    console.log('No sprints recorded yet.');
    return;
  }

  console.log('╔══════════════════════════════════════════════════════════════════╗');
  console.log('║  SPRINT HISTORY                                                  ║');
  console.log('╠══════════════════════════════════════════════════════════════════╣');

  for (const sprint of sprints) {
    const date = new Date(sprint.date).toLocaleDateString();
    const tasks = `${sprint.totals.tasks_completed}/${sprint.totals.tasks_completed + sprint.totals.tasks_failed}`;
    const cost = `$${sprint.totals.cost_usd.toFixed(2)}`;
    const duration = `${Math.round(sprint.totals.duration_seconds / 60)}m`;

    console.log(`║  ${sprint.id.padEnd(25)} │ ${date.padEnd(12)} │ ${tasks.padEnd(5)} │ ${cost.padEnd(7)} │ ${duration.padEnd(5)} ║`);
    console.log(`║    ${sprint.goal.substring(0, 60).padEnd(60)} ║`);
    console.log('╠──────────────────────────────────────────────────────────────────╣');
  }

  console.log(`║  Showing ${sprints.length} of ${history.sprints.length} sprints`.padEnd(67) + '║');
  console.log('╚══════════════════════════════════════════════════════════════════╝');
}

// Show statistics
function showStats() {
  const history = loadHistory();
  const { cumulative } = history;
  const sprints = history.sprints;

  // Calculate additional stats
  const costByMonth = {};
  const tasksByCategory = {};

  for (const sprint of sprints) {
    const month = sprint.date.substring(0, 7);
    costByMonth[month] = (costByMonth[month] || 0) + sprint.totals.cost_usd;

    for (const task of sprint.tasks || []) {
      const category = task.title.split(' ')[0];
      tasksByCategory[category] = (tasksByCategory[category] || 0) + 1;
    }
  }

  console.log('╔══════════════════════════════════════════════════════════════════╗');
  console.log('║  SPRINT STATISTICS                                               ║');
  console.log('╠══════════════════════════════════════════════════════════════════╣');
  console.log(`║  Total Sprints:        ${String(cumulative.total_sprints).padStart(6)}                                ║`);
  console.log(`║  Total Tasks:          ${String(cumulative.total_tasks).padStart(6)}                                ║`);
  console.log(`║  Total Cost:           $${cumulative.total_cost_usd.toFixed(2).padStart(6)}                                ║`);
  console.log(`║  Total Duration:       ${String(Math.round(cumulative.total_duration_seconds / 60)).padStart(6)}m                               ║`);
  console.log('╠──────────────────────────────────────────────────────────────────╣');
  console.log(`║  Avg Cost/Sprint:      $${cumulative.average_cost_per_sprint.toFixed(2).padStart(6)}                                ║`);
  console.log(`║  Avg Tasks/Sprint:     ${String(cumulative.average_tasks_per_sprint).padStart(6)}                                ║`);
  console.log('╠──────────────────────────────────────────────────────────────────╣');
  console.log('║  COST BY MONTH                                                   ║');

  for (const [month, cost] of Object.entries(costByMonth).slice(-6)) {
    console.log(`║    ${month}:  $${cost.toFixed(2).padStart(7)}                                        ║`);
  }

  console.log('╚══════════════════════════════════════════════════════════════════╝');
}

// Generate detailed report
function generateReport(sprintId) {
  const history = loadHistory();
  const sprint = sprintId
    ? history.sprints.find(s => s.id === sprintId)
    : history.sprints[history.sprints.length - 1];

  if (!sprint) {
    console.log(`Sprint ${sprintId || 'latest'} not found.`);
    return;
  }

  const report = `
# Sprint Report: ${sprint.id}

**Date:** ${new Date(sprint.date).toLocaleString()}
**Goal:** ${sprint.goal}
**Mode:** ${sprint.mode || 'standard'}

## Summary

| Metric | Value |
|--------|-------|
| Tasks Completed | ${sprint.totals.tasks_completed} |
| Tasks Failed | ${sprint.totals.tasks_failed} |
| Duration | ${Math.round(sprint.totals.duration_seconds / 60)} minutes |
| Total Cost | $${sprint.totals.cost_usd.toFixed(2)} |

## Tasks

${(sprint.tasks || []).map(t => `
### ${t.title}
- **Status:** ${t.status}
- **Result:** ${t.result || 'N/A'}
- **Duration:** ${Math.round((t.duration_seconds || 0) / 60)}m
- **Cost:** $${(t.cost_usd || 0).toFixed(2)}
`).join('\n')}

## Files Changed

${(sprint.files_changed || []).map(f => `- ${f}`).join('\n')}

## Commit

- **Hash:** ${sprint.commit?.hash || 'N/A'}
- **Message:** ${sprint.commit?.message || 'N/A'}

${sprint.notes ? `## Notes\n\n${sprint.notes}` : ''}
`;

  console.log(report);
  return report;
}

// Export to markdown
function exportToMarkdown() {
  const history = loadHistory();

  let md = `# Multi-Session Sprint History

Generated: ${new Date().toISOString()}

## Cumulative Statistics

| Metric | Value |
|--------|-------|
| Total Sprints | ${history.cumulative.total_sprints} |
| Total Tasks | ${history.cumulative.total_tasks} |
| Total Cost | $${history.cumulative.total_cost_usd.toFixed(2)} |
| Avg Cost/Sprint | $${history.cumulative.average_cost_per_sprint.toFixed(2)} |

## Sprint Log

| Date | Sprint ID | Goal | Tasks | Cost | Duration |
|------|-----------|------|-------|------|----------|
`;

  for (const sprint of history.sprints.reverse()) {
    const date = new Date(sprint.date).toLocaleDateString();
    const tasks = `${sprint.totals.tasks_completed}/${sprint.totals.tasks_completed + sprint.totals.tasks_failed}`;
    md += `| ${date} | ${sprint.id} | ${sprint.goal.substring(0, 30)}... | ${tasks} | $${sprint.totals.cost_usd.toFixed(2)} | ${Math.round(sprint.totals.duration_seconds / 60)}m |\n`;
  }

  console.log(md);
  return md;
}

// Export to CSV
function exportToCsv() {
  const history = loadHistory();

  let csv = 'sprint_id,date,goal,tasks_completed,tasks_failed,cost_usd,duration_minutes,commit_hash\n';

  for (const sprint of history.sprints) {
    csv += `"${sprint.id}","${sprint.date}","${sprint.goal.replace(/"/g, '""')}",${sprint.totals.tasks_completed},${sprint.totals.tasks_failed},${sprint.totals.cost_usd},${Math.round(sprint.totals.duration_seconds / 60)},"${sprint.commit?.hash || ''}"\n`;
  }

  console.log(csv);
  return csv;
}

// Main CLI handler
const command = process.argv[2];
const args = process.argv.slice(3);

switch (command) {
  case 'add':
    if (args[0]) {
      addSprint(args[0]);
    } else {
      // Read from stdin
      let data = '';
      process.stdin.on('data', chunk => data += chunk);
      process.stdin.on('end', () => addSprint(data));
    }
    break;

  case 'list':
    const limit = args.includes('--limit')
      ? parseInt(args[args.indexOf('--limit') + 1])
      : 10;
    listSprints(limit);
    break;

  case 'stats':
    showStats();
    break;

  case 'report':
    generateReport(args[0]);
    break;

  case 'export':
    if (args[0] === 'csv') {
      exportToCsv();
    } else {
      exportToMarkdown();
    }
    break;

  case 'last':
    // Quick access to last sprint
    const h = loadHistory();
    if (h.sprints.length > 0) {
      console.log(JSON.stringify(h.sprints[h.sprints.length - 1], null, 2));
    }
    break;

  default:
    console.log(`Sprint Tracker - Track multi-session sprint costs and results

Usage:
  node sprint-tracker.mjs add <json>      Add new sprint record
  node sprint-tracker.mjs list [--limit N] List recent sprints
  node sprint-tracker.mjs stats           Show statistics
  node sprint-tracker.mjs report [id]     Generate sprint report
  node sprint-tracker.mjs export [md|csv] Export history
  node sprint-tracker.mjs last            Show last sprint (JSON)
`);
}

// Export for programmatic use
export { loadHistory, saveHistory, addSprint, generateSprintId, updateCumulativeStats };
