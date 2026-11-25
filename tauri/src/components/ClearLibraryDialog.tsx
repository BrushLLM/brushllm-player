import { useLayoutEffect, useRef } from "react";
import { useI18n } from "../i18n";

interface ClearLibraryDialogProps {
  label: string;
  onConfirm: () => void;
  onClose: () => void;
}

export default function ClearLibraryDialog({ label, onConfirm, onClose }: ClearLibraryDialogProps) {
  const { t } = useI18n();
  const dialog = useRef<HTMLDialogElement>(null);
  const cancel = useRef<HTMLButtonElement>(null);

  useLayoutEffect(() => {
    const element = dialog.current;
    const opener = document.activeElement;
    element?.showModal();
    cancel.current?.focus();
    return () => {
      element?.close();
      if (opener instanceof HTMLElement && opener.isConnected) opener.focus();
    };
  }, []);

  return (
    <dialog ref={dialog} className="about-dialog clear-dialog" aria-labelledby="clear-title"
      aria-describedby="clear-description" onCancel={(event) => { event.preventDefault(); onClose(); }}>
      <h2 id="clear-title">{t("panel.clear.question")}</h2>
      <p id="clear-description">{t("panel.clear.description")}</p>
      <div className="clear-actions">
        <button ref={cancel} className="dialog-action" type="button" onClick={onClose}>{t("panel.cancel")}</button>
        <button className="dialog-action danger" type="button" onClick={onConfirm}>{label}</button>
      </div>
    </dialog>
  );
}
