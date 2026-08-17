alter table public.account_management_audit_logs
  drop constraint if exists account_management_audit_logs_action_check;

alter table public.account_management_audit_logs
  add constraint account_management_audit_logs_action_check check (
    action in (
      'user_created',
      'user_disabled',
      'user_enabled',
      'temporary_password_reset',
      'password_changed',
      'branch_created',
      'branch_assignment_added',
      'branch_assignment_removed',
      'branch_role_changed',
      'daily_audit_pin_configured',
      'daily_audit_pin_replaced',
      'daily_audit_access_granted',
      'daily_audit_user_access_granted',
      'daily_audit_user_access_revoked',
      'daily_audit_access_user_created',
      'daily_audit_access_user_revoked',
      'maintenance_access_user_created',
      'maintenance_access_user_deactivated',
      'maintenance_user_created',
      'maintenance_user_deactivated',
      'branch_shift_created',
      'branch_shift_updated',
      'supervisor_team_assigned',
      'supervisor_team_deactivated',
      'operational_staff_created',
      'operational_staff_updated',
      'operational_staff_deactivated',
      'operational_staff_assignment_created',
      'operational_staff_assignment_updated',
      'operational_staff_assignment_deactivated',
      'operational_staff_duty_changed',
      'organization_logo_updated',
      'branch_logo_updated'
    )
  );
