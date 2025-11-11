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

2. **Check for subtasks (CRITICAL)**
   - Use `mcp__backlog__task_list` with search="$1" to find all subtasks
   - Subtasks are identified by IDs like "$1.1", "$1.2", "$1.3", etc.
   - Review the status of each subtask to get the big picture:
     - "Done" - Already completed, skip
     - "In Progress" - Continue working on this one
     - "To Do" - Next subtask to work on
   - **If subtasks exist, work on them in order rather than the parent task**
   - Only mark the parent task as "Done" when ALL subtasks are complete

3. **Understand the work scope**
   - Read the full task description and implementation notes
   - If working on a subtask, focus on that subtask's specific scope
   - If the task has acceptance criteria, treat each criterion as a work item
   - If there are dependencies, check if they need to be completed first
   - Understand the technical requirements and context

4. **Create a work plan**
   - Use the TodoWrite tool to create a structured task list
   - Break down the work into small, testable increments
   - Include each acceptance criterion as a separate todo item
   - Plan to update task status as you progress

5. **Update task status**
   - If working on a subtask, set the subtask status to "In Progress"
   - If the parent task is not yet "In Progress", update it as well
   - Add your name to the assignee list if not already there

6. **Execute the work**
   - Follow the development guidelines in CLAUDE.md
   - Work incrementally with frequent commits
   - Run tests after each significant change
   - Update the task's implementation notes as you discover important details
   - Check off acceptance criteria as you complete them using `mcp__backlog__task_edit`

7. **Handle blockers**
   - If you encounter issues, update the task's implementation notes
   - If you get stuck after 3 attempts, document what failed and ask the user
   - Consider creating new tasks for discovered work

8. **Complete the task**
   - Ensure all acceptance criteria are checked off
   - Run the full test suite and precommit checks
   - Update the task status to "Done" using `mcp__backlog__task_edit`
   - Add completion notes documenting what was done
   - If this is a subtask, check if all sibling subtasks are done before marking parent complete

## Important Reminders

- Always read the task details FIRST before starting any work
- Keep the task status updated as you progress
- Use acceptance criteria as your checklist for completion
- Document blockers and decisions in the task's implementation notes
- Don't mark the task as done until ALL acceptance criteria are met
