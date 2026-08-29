import { memo } from "react";
import { useI18n } from "../i18n";
import styles from "./CodexModeControls.module.css";

interface CodexModeControlsProps {
  fastEnabled: boolean;
  ultraEnabled: boolean;
  fastAvailable?: boolean;
  ultraAvailable?: boolean;
  ultraLevelLabel?: string;
  disabled?: boolean;
  compact?: boolean;
  onFastChange: (enabled: boolean) => void;
  onUltraChange: (enabled: boolean) => void;
}

export const CodexModeControls = memo(function CodexModeControls({
  fastEnabled,
  ultraEnabled,
  fastAvailable = true,
  ultraAvailable = true,
  ultraLevelLabel,
  disabled = false,
  compact = false,
  onFastChange,
  onUltraChange,
}: CodexModeControlsProps) {
  const { t } = useI18n();

  return (
    <div
      className={`${styles.root}${compact ? ` ${styles.compact}` : ""}`}
      role="group"
      aria-label={t("codexModesLabel")}
    >
      <button
        type="button"
        className={`${styles.mode}${fastEnabled ? ` ${styles.active}` : ""}`}
        aria-pressed={fastEnabled}
        disabled={disabled || !fastAvailable}
        title={
          fastAvailable
            ? t("codexFastDescription")
            : t("codexFastUnavailable")
        }
        onClick={() => onFastChange(!fastEnabled)}
      >
        <span className={styles.icon} aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none">
            <path d="M13.2 2 4.5 13.2h6.1L9.8 22l8.7-11.2h-6.1L13.2 2Z" />
          </svg>
        </span>
        <span className={styles.copy}>
          <strong>{t("codexFastLabel")}</strong>
          {!compact && <small>{t("codexFastHint")}</small>}
        </span>
      </button>

      <button
        type="button"
        className={`${styles.mode}${ultraEnabled ? ` ${styles.active}` : ""}`}
        aria-pressed={ultraEnabled}
        disabled={disabled || !ultraAvailable}
        title={
          ultraAvailable
            ? t("codexUltraDescription")
            : t("codexUltraUnavailable")
        }
        onClick={() => onUltraChange(!ultraEnabled)}
      >
        <span className={styles.icon} aria-hidden="true">
          <svg viewBox="0 0 24 24" fill="none">
            <path d="m12 2 1.55 5.45L19 9l-5.45 1.55L12 16l-1.55-5.45L5 9l5.45-1.55L12 2Z" />
            <path d="m18.5 14 .8 2.7 2.7.8-2.7.8-.8 2.7-.8-2.7-2.7-.8 2.7-.8.8-2.7Z" />
          </svg>
        </span>
        <span className={styles.copy}>
          <strong>{t("codexUltraLabel")}</strong>
          {!compact && (
            <small>
              {ultraLevelLabel
                ? t("codexUltraHintLevel", { level: ultraLevelLabel })
                : t("codexUltraHint")}
            </small>
          )}
        </span>
      </button>
    </div>
  );
});
