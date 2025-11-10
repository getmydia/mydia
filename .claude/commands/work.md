---
argument-hint: <task-id>
description: Start working on a backlog task and its sub-tasks
---

# Work on Backlog Task

You are now starting work on backlog task **$1**.

## Instructions

1. **Fetch the task details**
   - Use `mcp__backlog__task_view` with id "$1" to get complete task information
   - Review the task title, description, status, priority, and labels
   - Check for implementation plan/notes if they exist
   - Review acceptance criteria (these are often sub-tasks to complete)
   - Note any dependencies listed

2. **Understand the work scope**
   - Read the full task description and implementation notes
   - If the task has acceptance criteria, treat each criterion as a sub-task
   - If there are dependencies, check if they need to be completed first
   - Understand the technical requirements and context

3. **Create a work plan**
   - Use the TodoWrite tool to create a structured task list
   - Break down the work into small, testable increments
   - Include each acceptance criterion as a separate todo item
   - Plan to update task status as you progress

4. **Update task status**
   - Use `mcp__backlog__task_edit` to set the task status to "In Progress"
   - Add your name to the assignee list if not already there

5. **Execute the work**
   - Follow the development guidelines in CLAUDE.md
   - Work incrementally with frequent commits
   - Run tests after each significant change
   - Update the task's implementation notes as you discover important details
   - Check off acceptance criteria as you complete them using `mcp__backlog__task_edit`

6. **Handle blockers**
   - If you encounter issues, update the task's implementation notes
   - If you get stuck after 3 attempts, document what failed and ask the user
   - Consider creating new tasks for discovered work

7. **Complete the task**
   - Ensure all acceptance criteria are checked off
   - Run the full test suite and precommit checks
   - Update the task status to "Done" using `mcp__backlog__task_edit`
   - Add completion notes documenting what was done

## Important Reminders

- Always read the task details FIRST before starting any work
- Keep the task status updated as you progress
- Use acceptance criteria as your checklist for completion
- Document blockers and decisions in the task's implementation notes
- Don't mark the task as done until ALL acceptance criteria are met
