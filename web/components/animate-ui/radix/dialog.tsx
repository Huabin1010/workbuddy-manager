'use client';

import * as React from 'react';
import {Dialog as DialogPrimitive} from 'radix-ui';
import {X} from 'lucide-react';
import {
  AnimatePresence,
  motion,
  usePresence,
  type HTMLMotionProps,
  type Transition,
} from 'motion/react';

import {cn} from '@/lib/utils';
import {ScrollArea} from '@/components/ui/scroll-area';

type DialogContextType = {
  isOpen: boolean;
};

const DialogContext = React.createContext<DialogContextType | undefined>(
    undefined,
);

const useDialog = (): DialogContextType => {
  const context = React.useContext(DialogContext);
  if (!context) {
    throw new Error('useDialog must be used within a Dialog');
  }
  return context;
};

type DialogProps = React.ComponentProps<typeof DialogPrimitive.Root>;

function Dialog({children, open, defaultOpen, onOpenChange, ...props}: DialogProps) {
  const [uncontrolledOpen, setUncontrolledOpen] = React.useState(defaultOpen ?? false);
  const isControlled = open !== undefined;
  // 受控时直接用 props，不要再经 useEffect 抄一份。晚一帧会让遮罩的 CSS
  // 动画和 motion 各播一遍，打开时看起来像闪了两下。
  const isOpen = isControlled ? open : uncontrolledOpen;

  const handleOpenChange = React.useCallback(
      (next: boolean) => {
        if (!isControlled) setUncontrolledOpen(next);
        onOpenChange?.(next);
      },
      [isControlled, onOpenChange],
  );

  return (
    <DialogContext.Provider value={{isOpen}}>
      <DialogPrimitive.Root
        data-slot="dialog"
        {...props}
        open={isOpen}
        onOpenChange={handleOpenChange}
      >
        {children}
      </DialogPrimitive.Root>
    </DialogContext.Provider>
  );
}

type DialogTriggerProps = React.ComponentProps<typeof DialogPrimitive.Trigger>;

function DialogTrigger(props: DialogTriggerProps) {
  return <DialogPrimitive.Trigger data-slot="dialog-trigger" {...props} />;
}

type DialogPortalProps = React.ComponentProps<typeof DialogPrimitive.Portal>;

function DialogPortal(props: DialogPortalProps) {
  return <DialogPrimitive.Portal data-slot="dialog-portal" {...props} />;
}

type DialogCloseProps = React.ComponentProps<typeof DialogPrimitive.Close>;

function DialogClose(props: DialogCloseProps) {
  return <DialogPrimitive.Close data-slot="dialog-close" {...props} />;
}

type DialogOverlayProps = React.ComponentProps<typeof DialogPrimitive.Overlay>;

function DialogOverlay({className, ...props}: DialogOverlayProps) {
  return (
    <DialogPrimitive.Overlay
      data-slot="dialog-overlay"
      className={cn(
          'fixed inset-0 z-50 bg-black/16 backdrop-blur-[2px] dark:bg-black/55',
          className,
      )}
      {...props}
    />
  );
}

type FlipDirection = 'top' | 'bottom' | 'left' | 'right';

type DialogContentProps = React.ComponentProps<typeof DialogPrimitive.Content> &
  HTMLMotionProps<'div'> & {
    from?: FlipDirection;
    transition?: Transition;
    showCloseButton?: boolean;
  };

// 只做透明度。位移交给 CSS 的 translate（Tailwind v4 的独立属性），
// 不要再写 transform / scale：那两套会互相覆盖，弹窗会先跳一下再落到正中。
const DIALOG_EASE = [0.22, 1, 0.36, 1] as const;
const DIALOG_TRANSITION: Transition = {duration: 0.28, ease: DIALOG_EASE};

function dialogShift(from: FlipDirection): {x: number; y: number} {
  if (from === 'left') return {x: -10, y: 0};
  if (from === 'right') return {x: 10, y: 0};
  if (from === 'bottom') return {x: 0, y: -8};
  return {x: 0, y: 8};
}

function DialogContent({
  className,
  children,
  from = 'top',
  transition: _transition,
  showCloseButton = true,
  ...props
}: DialogContentProps) {
  void _transition;
  const {isOpen} = useDialog();

  return (
    <AnimatePresence>
      {isOpen ? (
        <DialogMotionLayer
          key="dialog"
          className={className}
          from={from}
          showCloseButton={showCloseButton}
          {...props}
        >
          {children}
        </DialogMotionLayer>
      ) : null}
    </AnimatePresence>
  );
}

function DialogMotionLayer({
  className,
  children,
  from = 'top',
  showCloseButton = true,
  ...props
}: DialogContentProps) {
  const [isPresent, safeToRemove] = usePresence();
  const shift = dialogShift(from);
  const settled = {opacity: 1, x: 0, y: 0};
  const hidden = {opacity: 0, x: shift.x, y: shift.y};

  // 退出动画被打断时 onAnimationComplete 不一定会来，留一个兜底拆掉门户。
  React.useEffect(() => {
    if (isPresent) return;
    const id = window.setTimeout(safeToRemove, 360);
    return () => window.clearTimeout(id);
  }, [isPresent, safeToRemove]);

  return (
    <DialogPortal forceMount>
      <DialogOverlay asChild forceMount>
        <motion.div
          initial={{opacity: 0}}
          animate={{opacity: isPresent ? 1 : 0}}
          transition={DIALOG_TRANSITION}
        />
      </DialogOverlay>
      <DialogPrimitive.Content asChild forceMount {...props}>
        <motion.div
          data-slot="dialog-content"
          initial={hidden}
          animate={isPresent ? settled : hidden}
          transition={DIALOG_TRANSITION}
          onAnimationComplete={() => {
            if (!isPresent) safeToRemove();
          }}
          className={cn(
              // 背景使用不透明色：半透明会让背后遮罩透出，与不透明的 header/footer
              // 形成明暗分界，看起来像「双层边框」。同时只保留一条 border，
              // 不再叠加 ring，避免边框外侧多出一圈描边。
              //
              // ⚠️ 这里**只能**用不带响应式前缀的 max-w-lg，不要写成 max-w-lg sm:max-w-lg。
              // Tailwind 把响应式变体的规则排在样式表靠后的位置，所以 `sm:max-w-lg`
              // 会**盖过**调用方传进来的 `max-w-[900px]`（两者不在同一个变体组，
              // tailwind-merge 认为它们不冲突、都会保留），结果是任何 ≥640px 的屏幕
              // 上所有弹窗都被压回 512px。历史上 7 个弹窗的宽度覆盖全部因此失效过。
              'fixed left-[50%] top-[50%] z-50 grid w-[calc(100%-2rem)] max-w-lg translate-x-[-50%] translate-y-[-50%] gap-0 overflow-hidden rounded-[24px] border border-border/60 bg-background shadow-[0_24px_60px_rgba(15,23,42,0.10)] dark:border-border/70 dark:bg-background dark:shadow-[0_24px_60px_rgba(0,0,0,0.42)]',
              className,
          )}
        >
          {children}
          {showCloseButton && (
            <DialogPrimitive.Close className="absolute right-4 top-4 rounded-sm opacity-70 ring-offset-background transition-opacity hover:opacity-100 focus:outline-none focus:ring-2 focus:ring-ring focus:ring-offset-2 disabled:pointer-events-none data-[state=open]:bg-accent data-[state=open]:text-muted-foreground">
              <X className="h-4 w-4" />
              <span className="sr-only">Close</span>
            </DialogPrimitive.Close>
          )}
        </motion.div>
      </DialogPrimitive.Content>
    </DialogPortal>
  );
}

type DialogHeaderProps = React.ComponentProps<'div'>;

function DialogHeader({className, ...props}: DialogHeaderProps) {
  return (
    <div
      data-slot="dialog-header"
      className={cn(
          'flex flex-col gap-1.5 px-6 py-4 text-left bg-background',
          className,
      )}
      {...props}
    />
  );
}

type DialogFooterProps = React.ComponentProps<'div'>;

function DialogFooter({className, ...props}: DialogFooterProps) {
  return (
    <div
      data-slot="dialog-footer"
      className={cn(
          'flex flex-row justify-end gap-2 px-6 py-4 bg-background',
          className,
      )}
      {...props}
    />
  );
}

type DialogBodyProps = React.ComponentProps<typeof ScrollArea>;

/**
 * 弹窗主体（可滚动）。
 *
 * ⚠️ `className` 落在 Radix ScrollArea 的 **Root** 上，而 children 被塞进内层的
 * Viewport —— 所以这里**只能写结构性类**（限高 `max-h-[…]` 之类）。布局类
 * （`space-y-*` / `px-*` / `py-*`）必须再套一层 div：
 *
 *   <DialogBody className="max-h-[min(640px,calc(100dvh-12rem))]">
 *     <div className="space-y-4 px-6 pb-2">…字段…</div>
 *   </DialogBody>
 *
 * 写成 `<DialogBody className="space-y-3 px-6">` 不会报错，但 space-y-3 会作用到
 * Root 的 Viewport / ScrollBar / Corner 三个兄弟节点上，字段之间**一个间距都没有**
 * —— 表现为「所有字段挤成一坨」（上游表单与移动分组弹窗都踩过这个坑）。
 * 横向的 px-* 则"碰巧"有效：Root 的内边距会把 Viewport 挤窄，看起来像是生效了，
 * 更容易骗过肉眼。
 */
function DialogBody({className, children, ...props}: DialogBodyProps) {
  return (
    <ScrollArea
      data-slot="dialog-body"
      className={cn('min-h-0 flex-1', className)}
      {...props}
    >
      {children}
    </ScrollArea>
  );
}

type DialogTitleProps = React.ComponentProps<typeof DialogPrimitive.Title>;

function DialogTitle({className, ...props}: DialogTitleProps) {
  return (
    <DialogPrimitive.Title
      data-slot="dialog-title"
      className={cn(
          'text-lg font-semibold leading-none tracking-tight',
          className,
      )}
      {...props}
    />
  );
}

type DialogDescriptionProps = React.ComponentProps<
  typeof DialogPrimitive.Description
>;

function DialogDescription({className, ...props}: DialogDescriptionProps) {
  return (
    <DialogPrimitive.Description
      data-slot="dialog-description"
      className={cn('text-xs text-muted-foreground pt-1', className)}
      {...props}
    />
  );
}

export {
  Dialog,
  DialogPortal,
  DialogOverlay,
  DialogClose,
  DialogTrigger,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogBody,
  DialogTitle,
  DialogDescription,
  useDialog,
  type DialogContextType,
  type DialogProps,
  type DialogTriggerProps,
  type DialogPortalProps,
  type DialogCloseProps,
  type DialogOverlayProps,
  type DialogContentProps,
  type DialogHeaderProps,
  type DialogFooterProps,
  type DialogBodyProps,
  type DialogTitleProps,
  type DialogDescriptionProps,
};
